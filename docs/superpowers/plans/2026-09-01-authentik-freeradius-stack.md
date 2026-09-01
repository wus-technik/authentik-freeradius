# authentik + FreeRADIUS WPA2/3-Enterprise Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn this repository into a Portainer-deployable stack in which FreeRADIUS terminates EAP-TTLS from UniFi access points and proxies the inner PAP request to the authentik RADIUS outpost, with a CI-built container image and an end-to-end test that catches behavioural regressions.

**Architecture:** Two containers on a private Docker network. `authentik_radius` is the stock authentik RADIUS outpost, which speaks PAP only. `freeradius` is our image: it owns the TLS server certificate, terminates the EAP-TTLS tunnel from the APs, unwraps the inner PAP exchange, and proxies it to the outpost as an ordinary RADIUS Access-Request. All configuration arrives through environment variables read by FreeRADIUS's native `$ENV{}` expansion, so no secret is ever written to disk.

**Tech Stack:** FreeRADIUS 3.2.10 (Alpine), Docker Compose v2, GitHub Actions, GHCR, `eapol_test` (from `wpa_supplicant`) as the 802.1X test supplicant.

**Spec:** `docs/superpowers/specs/2026-09-01-authentik-freeradius-stack-design.md` — read it before starting. Section 4 explains *why* each change is being made; several look arbitrary without it.

## Global Constraints

Copy these values verbatim. Every task's requirements implicitly include this section.

- **Base image:** `freeradius/freeradius-server:3.2.10-alpine` — pinned, never `latest-3.2-alpine`.
- **`status_check = none`** on the `home_server`. **Never `status-server`.** The authentik outpost does not implement RFC 5997; with status checks enabled the home server never revives once dead and the WiFi stays down permanently. See spec §4.12.
- **`tls_max_version = "1.2"`** — not 1.3, for supplicant compatibility. See spec §5.3.
- **No `dh_file`, no DH parameter generation, no `openssl` package in the runtime image.** FreeRADIUS 3.2 handles DH itself. See spec §4.13.
- **No `ca_file`** in the EAP `tls-config`. It is the *client*-certificate trust anchor set, not the server chain. See spec §4.14.
- **Secrets are quoted** in FreeRADIUS config: `secret = "$ENV{VAR}"`. Unquoted, a secret beginning `0x` parses as a binary literal.
- **`radiusd` runs with `-f -l stdout`.** Without `-f` it daemonises and the container exits.
- **`radclient` exit status must never be read through a pipe.** `radclient … | tail` yields the pipeline's status (always 0), producing a healthcheck that can never fail.
- **GitHub Actions majors, all verified `using: node24`:** `actions/checkout@v7`, `docker/setup-qemu-action@v4`, `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/metadata-action@v6`, `docker/build-push-action@v7`. Do not downgrade any of these.
- **Registry:** `ghcr.io/wus-technik/authentik-freeradius`, public package.
- **Do not add a `LICENSE` file** and do not set `org.opencontainers.image.licenses`. The licence is an open decision (spec §8).
- **Language:** all committed text — code comments, docs, commit messages, issue bodies — in English.
- **Commit trailers:** never add a Claude/AI co-author trailer.

## Pre-verified during planning

These were run against real containers before this plan was written, so an executor hitting
a failure in one of them should suspect a transcription error rather than a design fault:

- `mods/eap` with **no `ca_file` and no `dh_file`**, `tls_max_version = "1.2"`, `$ENV{}`
  certificate paths — `radiusd -XC` clean, full EAP-TTLS handshake `SUCCESS` with MPPE keys.
- `entrypoint.sh` exactly as written in Task 2 Step 4 — fail-fast messages fire correctly
  for both a missing environment variable and a missing certificate mount.
- `healthcheck.sh` as written in Task 2 Step 5 — the container reaches `healthy`.
- `CERT_RELOAD_WATCH=true` — modifying the certificate on the host restarts the container,
  which comes back `healthy`. The `$$`-before-`exec` trick for signalling radiusd works.
- `read_only: true` + `cap_drop: [ALL]` with tmpfs on `/run/radiusd`, `/tmp/radiusd` and
  `/var/run` — container healthy, authentication working.
- The image contains **no `openssl`**, confirming the DH removal dropped that dependency.
  This is why the e2e rig generates its certificate from the *client* image.

## Design decision resolved during planning

Spec §8 left open whether the home-server address should be a literal (`authentik_radius`) or an `$ENV{}` variable. **This plan uses `$ENV{AUTHENTIK_RADIUS_HOST}`.** FreeRADIUS resolves `home_server` hostnames at config-parse time, so a literal makes `radiusd -XC` fail outside a Compose network; the variable lets CI set `127.0.0.1` and removes the need for `--add-host`. Compose sets it to `authentik_radius`.

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `freeradius/clients.conf` | Client definitions, home server, pool, realm. Replaces the `.template`. |
| `freeradius/healthcheck.sh` | Status-Server probe against localhost for `HEALTHCHECK`. |
| `docker-compose.yml` | The Portainer stack. Committed, image-based. |
| `docker-compose.override.yml.example` | Local development: build from source instead of pulling. |
| `.env.example` | Every variable, documented. Doubles as the Portainer paste-list. |
| `.github/workflows/build.yml` | Lint, validate, build, publish. |
| `test/e2e/docker-compose.test.yml` | The three-container rig. |
| `test/e2e/backend/Dockerfile` | PAP-only stand-in for the authentik outpost. |
| `test/e2e/client/Dockerfile` | `eapol_test` supplicant + `openssl` for cert generation. |
| `test/e2e/client/ttls.conf` | Supplicant profile. |
| `test/e2e/client/auth.sh` | One authentication attempt; exit status is the result. |
| `test/e2e/run.sh` | Drives the whole rig including the outage/recovery case. |
| `docs/authentik.md`, `docs/unifi.md`, `docs/clients.md`, `docs/troubleshooting.md` | Setup and operations. |

**Modified:** `Dockerfile`, `freeradius/radiusd.conf`, `freeradius/mods/eap`, `freeradius/entrypoint.sh`, `.gitignore`, `README.md`.

**Deleted:** `freeradius/clients.conf.template`, `environment/`, `img/`, `wpa2_supplicant.conf`, `docker-compose.yml.example`.

**Unchanged:** `freeradius/sites/site`, `freeradius/sites/proxy-inner-tunnel` — they are correct.

---

### Task 1: End-to-end test rig

Build the harness first. It is the only thing that catches the class of fault described in spec §4.12, which `radiusd -XC` accepts silently. It will fail at the end of this task because the image it tests does not exist yet — that is the point.

**Files:**
- Create: `test/e2e/docker-compose.test.yml`
- Create: `test/e2e/backend/Dockerfile`
- Create: `test/e2e/client/Dockerfile`
- Create: `test/e2e/client/ttls.conf`
- Create: `test/e2e/client/auth.sh`
- Create: `test/e2e/run.sh`
- Create: `test/e2e/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `test/e2e/run.sh`, executable, exit 0 on pass and non-zero on failure. Task 2 makes it pass; Task 5 calls it from CI. It builds the image under test from the repository root `Dockerfile` and requires these environment variables to be accepted by that image: `AUTHENTIK_RADIUS_HOST`, `AUTHENTIK_RADIUS_SECRET`, `RADIUS_SECRET`, `RADIUS_CLIENT_NET`, `TLS_CERT_PATH`, `TLS_KEY_PATH`.

- [ ] **Step 1: Write the backend stand-in**

This mimics the authentik outpost. `status_server = no` is the critical line — the stock FreeRADIUS config sets it to `yes`, and a stand-in that answers Status-Server hides exactly the bug this rig exists to catch.

Create `test/e2e/backend/Dockerfile`:

```dockerfile
# Stand-in for the authentik RADIUS outpost.
#
# The real outpost speaks PAP only and silently drops every packet that is not
# an Access-Request -- its ServeRADIUS has no else branch. status_server must
# therefore be "no" here, or this stand-in answers Status-Server when the real
# outpost never would, and the regression test in run.sh becomes meaningless.
FROM freeradius/freeradius-server:3.2.10-alpine

RUN printf '\nclient proxy {\n\tipaddr = 0.0.0.0/0\n\tsecret = "backendsecret"\n\trequire_message_authenticator = no\n}\n' \
      >> /etc/raddb/clients.conf \
 && sed -i '1i testuser Cleartext-Password := "testpw"' /etc/raddb/mods-config/files/authorize \
 && sed -i 's/^\([[:space:]]*\)status_server = yes/\1status_server = no/' /etc/raddb/radiusd.conf \
 && grep -q 'status_server = no' /etc/raddb/radiusd.conf

ENTRYPOINT ["/opt/sbin/radiusd", "-f", "-l", "stdout", "-d", "/etc/raddb"]
```

- [ ] **Step 2: Write the supplicant image and profile**

Alpine packages `eapol_test` inside `wpa_supplicant` at `/sbin/eapol_test`. `openssl` is here so the rig can generate its own throwaway server certificate — the image under test deliberately has no `openssl`.

Create `test/e2e/client/Dockerfile`:

```dockerfile
FROM alpine:3.21
RUN apk add --no-cache wpa_supplicant openssl
COPY ttls.conf /ttls.conf
COPY auth.sh /auth.sh
RUN chmod +x /auth.sh
```

Create `test/e2e/client/ttls.conf`:

```
network={
	ssid="e2e"
	key_mgmt=WPA-EAP
	eap=TTLS
	identity="testuser"
	anonymous_identity="anonymous"
	password="testpw"
	phase2="auth=PAP"
}
```

- [ ] **Step 3: Write the single-attempt auth script**

`eapol_test -a` takes an IP address, not a hostname, so resolve the service name first.

Create `test/e2e/client/auth.sh`:

```sh
#!/bin/sh
# One EAP-TTLS authentication attempt against the freeradius service.
# Exit 0 on Access-Accept, non-zero otherwise.
set -u

ip="$(getent hosts freeradius | awk '{print $1}' | head -1)"
if [ -z "$ip" ]; then
	echo "auth.sh: cannot resolve 'freeradius'" >&2
	exit 2
fi

# eapol_test -a requires an IP address, not a hostname.
eapol_test -c /ttls.conf -a "$ip" -p 1812 -s "${RADIUS_SECRET:-uplinksecret}" -r0 >/tmp/eapol.log 2>&1
rc=$?
tail -1 /tmp/eapol.log
exit "$rc"
```

- [ ] **Step 4: Write the compose rig**

Create `test/e2e/docker-compose.test.yml`:

```yaml
name: akfr-e2e

services:
  authentik_radius:
    build: ./backend
    networks: [e2e]

  certgen:
    build: ./client
    volumes:
      - ./certs:/out
    command:
      - sh
      - -c
      - >-
        test -f /out/server.crt ||
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650
        -subj '/CN=radius.e2e.test'
        -keyout /out/server.key -out /out/server.crt

  freeradius:
    build:
      context: ../..
      dockerfile: Dockerfile
    depends_on:
      authentik_radius:
        condition: service_started
    environment:
      AUTHENTIK_RADIUS_HOST: authentik_radius
      AUTHENTIK_RADIUS_SECRET: backendsecret
      RADIUS_SECRET: uplinksecret
      RADIUS_CLIENT_NET: 0.0.0.0/0
      TLS_CERT_PATH: /certs/server.crt
      TLS_KEY_PATH: /certs/server.key
    volumes:
      - ./certs:/certs:ro
    networks: [e2e]

  client:
    build: ./client
    environment:
      RADIUS_SECRET: uplinksecret
    networks: [e2e]
    entrypoint: ["/auth.sh"]

networks:
  e2e:
    driver: bridge
```

Create `test/e2e/.gitignore`:

```
certs/
```

- [ ] **Step 5: Write the test driver**

The outage/recovery case is the reason this rig exists. Write it first and keep it first.

Create `test/e2e/run.sh`:

```sh
#!/usr/bin/env bash
# End-to-end test for the EAP-TTLS -> inner PAP -> authentik proxy chain.
#
# The recovery case is the important one: with status_check = status-server a
# dead home server never revives, because the authentik outpost never answers
# Status-Server. That fault passes `radiusd -XC` without complaint, so only a
# live outage test catches it. See spec section 4.12.
set -euo pipefail

# Git Bash on Windows rewrites container-side paths otherwise.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.test.yml)
REVIVE_WAIT="${REVIVE_WAIT:-75}"

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

auth() { "${COMPOSE[@]}" run --rm --quiet-pull client >/dev/null 2>&1; }

echo "== building =="
"${COMPOSE[@]}" build --quiet
"${COMPOSE[@]}" run --rm certgen >/dev/null

echo "== starting stack =="
"${COMPOSE[@]}" up -d authentik_radius freeradius
sleep 10

echo "== 1/4 baseline authentication =="
auth || fail "baseline EAP-TTLS authentication did not succeed"
echo "   ok"

echo "== 2/4 outage: stopping the outpost =="
"${COMPOSE[@]}" stop authentik_radius >/dev/null

# The home server must actually reach the "dead" state before recovery is
# tested -- status checks only run against a dead home server, so restarting
# the backend while it is merely "zombie" lets a broken status_check pass.
# Wait for the state transition in the log rather than guessing at a sleep.
deadline=$(( $(date +%s) + 120 ))
while :; do
	auth || true
	if "${COMPOSE[@]}" logs freeradius 2>&1 | grep -q 'as dead'; then
		break
	fi
	[ "$(date +%s)" -lt "$deadline" ] || fail "home server never reached the dead state within 120s; the outage test cannot prove anything"
	sleep 5
done
echo "   home server is dead, as required"

if auth; then fail "authentication succeeded while the outpost was stopped"; fi
echo "   ok (correctly failing)"

echo "== 3/4 recovery: restarting the outpost =="
"${COMPOSE[@]}" start authentik_radius >/dev/null
sleep "$REVIVE_WAIT"
if ! auth; then
	echo "--- freeradius log ---" >&2
	"${COMPOSE[@]}" logs freeradius 2>&1 | grep -iE 'zombie|dead|alive' >&2 || true
	fail "home server never revived after the outpost came back. \
Check that status_check = none in freeradius/clients.conf -- with status-server \
it can never revive, because the authentik outpost does not answer Status-Server."
fi
echo "   ok"

echo "== 4/4 container healthcheck =="
cid="$("${COMPOSE[@]}" ps -q freeradius)"
[ -n "$cid" ] || fail "freeradius container is not running"
health="$(docker inspect --format '{{.State.Health.Status}}' "$cid")"
[ "$health" = "healthy" ] || fail "freeradius container health is '${health:-unknown}', expected 'healthy'"
echo "   ok"

echo
echo "PASS: all end-to-end checks succeeded"
```

- [ ] **Step 6: Make it executable and run it to verify it fails**

```bash
chmod +x test/e2e/run.sh test/e2e/client/auth.sh
git update-index --chmod=+x test/e2e/run.sh test/e2e/client/auth.sh 2>/dev/null || true
./test/e2e/run.sh
```

Expected: **FAIL**, before Task 2 is done. The old `Dockerfile` still builds (it copies `clients.conf.template` and generates DH parameters), so the failure comes later — at container startup or at `== 1/4 baseline authentication ==`, because the old entrypoint ignores `TLS_CERT_PATH` and looks for certificates under `${certdir}` where the rig has not put them.

Do **not** require the failure to happen during `== building ==`. What matters is that the suite does not pass: that confirms it is genuinely exercising the image rather than succeeding vacuously.

- [ ] **Step 7: Commit**

```bash
git add test/e2e
git commit -m "test: add end-to-end EAP-TTLS rig with outage/recovery case

Three containers: the image under test, a PAP-only stand-in for the
authentik outpost with status_server disabled, and eapol_test as an
802.1X supplicant.

The recovery case is the point. status_check = status-server against a
peer that never answers Status-Server leaves a dead home server dead
forever, and radiusd -XC accepts that configuration silently.

Refs goauthentik/authentik#5328"
```

---

### Task 2: FreeRADIUS configuration and image

Makes Task 1 pass.

**Files:**
- Create: `freeradius/clients.conf`
- Create: `freeradius/healthcheck.sh`
- Modify: `freeradius/mods/eap`
- Modify: `freeradius/radiusd.conf` (add one line after `hostname_lookups = no`)
- Rewrite: `freeradius/entrypoint.sh`
- Rewrite: `Dockerfile`
- Delete: `freeradius/clients.conf.template`
- Test: `test/e2e/run.sh`

**Interfaces:**
- Consumes: `test/e2e/run.sh` from Task 1.
- Produces: an image whose entrypoint requires `RADIUS_SECRET`, `AUTHENTIK_RADIUS_SECRET`, `RADIUS_CLIENT_NET`, `AUTHENTIK_RADIUS_HOST` and reads optional `TLS_CERT_PATH` (default `/etc/raddb/certs/server.crt`), `TLS_KEY_PATH` (default `/etc/raddb/certs/server.key`), `CERT_RELOAD_WATCH` (default `false`), `CERT_RELOAD_INTERVAL` (default `3600`), `FREERADIUS_ENABLE_DEBUG` (default `false`). Tasks 4 and 5 depend on exactly these names. The image exposes `1812/udp` and defines a `HEALTHCHECK`.

- [ ] **Step 1: Write `freeradius/clients.conf`**

Replaces the `sed`-templated file. Secrets come from the environment and are never written to disk.

```
#  Access points and controllers permitted to send requests.
#
#  require_message_authenticator is safe here only because this server
#  handles EAP exclusively -- RFC 3579 requires EAP Access-Requests to carry
#  Message-Authenticator, and it mitigates BlastRADIUS (CVE-2024-3596).
#  Adding MAB or any other non-EAP request type later means giving those
#  clients their own block with the requirement relaxed.
client uplink {
	ipaddr = $ENV{RADIUS_CLIENT_NET}
	secret = "$ENV{RADIUS_SECRET}"
	require_message_authenticator = yes
}

#  Loopback client for the container healthcheck. The secret is generated at
#  startup by entrypoint.sh and never leaves the container.
client healthcheck {
	ipaddr = 127.0.0.1
	secret = "$ENV{RADIUS_HEALTHCHECK_SECRET}"
	require_message_authenticator = yes
}

#  The authentik RADIUS outpost.
home_server authentik {
	type = auth
	ipaddr = $ENV{AUTHENTIK_RADIUS_HOST}
	port = 1812
	secret = "$ENV{AUTHENTIK_RADIUS_SECRET}"

	#  MUST stay "none".
	#
	#  The authentik outpost only handles Access-Request; its ServeRADIUS has
	#  no else branch, so Status-Server is silently dropped. FreeRADIUS uses
	#  status checks to revive a dead home server, so pointing them at a peer
	#  that never answers means the outpost, once marked dead, never comes
	#  back and every authentication fails until this container is restarted.
	#  Verified end to end; radiusd -XC does not catch it.
	status_check = none

	response_window = 10
	revive_interval = 60
}

home_server_pool authentik {
	type = fail-over
	home_server = authentik
}

realm authentik {
	auth_pool = authentik
	nostrip
}
```

- [ ] **Step 2: Update `freeradius/mods/eap`**

Replace the whole `tls-config tls-common` block and keep the `ttls` block. The file becomes:

```
eap {
	default_eap_type = ttls

	tls-config tls-common {

		#  Paths come from the environment so the certificates can live
		#  anywhere the operator mounts them -- in production, inside the
		#  read-only /etc/letsencrypt tree.
		private_key_file = $ENV{TLS_KEY_PATH}
		certificate_file = $ENV{TLS_CERT_PATH}

		#  No ca_file. In a tls-config this is the trust anchor set for
		#  CLIENT certificates, not the server's own chain -- auto_chain
		#  plus a fullchain.pem handles that. Pointing it at a public root
		#  store would mean any publicly-issued certificate is accepted as a
		#  client identity the moment EAP-TLS is enabled.

		#  No dh_file. FreeRADIUS 3.2 configures DH itself and logs
		#  "this is no longer necessary" if one is supplied.

		cipher_list = "HIGH"
		ecdh_curve = "secp384r1"
		include_length = yes
		fragment_size = 1024
		auto_chain = yes
		tls_min_version = "1.2"

		#  Not 1.3. FreeRADIUS 3.2's own eap comments advise against TLS 1.3
		#  for EAP because many supplicants implement it poorly. The tunnel
		#  carries one PAP exchange on a trusted LAN, so the gain is small
		#  and the failure mode is "staff cannot join the WiFi". Raise this
		#  only after per-platform client testing.
		tls_max_version = "1.2"

		#  Let's Encrypt stopped publishing OCSP URLs in early 2025 and shut
		#  its responders down in August 2025, so there is nothing to staple.
		#  ocsp validates CLIENT certificates and is inert for TTLS/PAP.
		staple {
			enable = no
		}

		ocsp {
			enable = no
		}

	}

	ttls {
		tls = tls-common
		default_eap_type = pap
		copy_request_to_tunnel = yes

		#  Carries authentik's reply attributes out of the tunnel. This is
		#  what dynamic VLAN assignment will need; note it copies ALL inner
		#  reply attributes outward.
		use_tunneled_reply = yes

		proxy_tunneled_request_as_eap = no
		include_length = yes
		virtual_server = "proxy-inner-tunnel"
	}
}
```

- [ ] **Step 3: Add `proxy_requests` to `freeradius/radiusd.conf`**

Find `hostname_lookups = no` and add one line directly after it:

```
hostname_lookups = no

#  This server exists to proxy. Do not rely on the built-in default.
proxy_requests = yes
```

- [ ] **Step 4: Rewrite `freeradius/entrypoint.sh`**

```sh
#!/bin/sh
#
# Validates the environment, generates the healthcheck secret, optionally
# watches the TLS certificate for renewal, then hands off to radiusd.
#
# Secrets are NOT templated into configuration files. FreeRADIUS expands
# $ENV{} natively, so they stay in the process environment and never touch
# the filesystem. The previous sed-based approach corrupted any secret
# containing / & or \.
set -eu

die() {
	echo "entrypoint: $*" >&2
	exit 1
}

for var in RADIUS_SECRET AUTHENTIK_RADIUS_SECRET RADIUS_CLIENT_NET AUTHENTIK_RADIUS_HOST; do
	eval "value=\${$var:-}"
	[ -n "$value" ] || die "required environment variable $var is unset or empty"
done

CERT_FILE="${TLS_CERT_PATH:-/etc/raddb/certs/server.crt}"
KEY_FILE="${TLS_KEY_PATH:-/etc/raddb/certs/server.key}"
export TLS_CERT_PATH="$CERT_FILE"
export TLS_KEY_PATH="$KEY_FILE"

[ -r "$CERT_FILE" ] || die "certificate '$CERT_FILE' is missing or unreadable (check the volume mount)"
[ -r "$KEY_FILE" ] || die "private key '$KEY_FILE' is missing or unreadable (check the volume mount)"

# Loopback-only secret for the container healthcheck. Regenerated every start;
# no default exists anywhere in the repository.
mkdir -p /run/radiusd
RADIUS_HEALTHCHECK_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export RADIUS_HEALTHCHECK_SECRET
( umask 077; printf '%s' "$RADIUS_HEALTHCHECK_SECRET" > /run/radiusd/healthcheck.secret )

# Hash the resolved content rather than stat the path: certbot repoints the
# live/ symlinks at new archive/ files, so mtime on the old inode never moves.
cert_fingerprint() {
	cat "$CERT_FILE" "$KEY_FILE" 2>/dev/null | md5sum | cut -d' ' -f1
}

watch_certificates() {
	target_pid="$1"
	baseline="$(cert_fingerprint)"
	while sleep "${CERT_RELOAD_INTERVAL:-3600}"; do
		if [ "$(cert_fingerprint)" != "$baseline" ]; then
			echo "entrypoint: certificate changed, restarting radiusd" >&2
			kill -TERM "$target_pid" 2>/dev/null || true
			return 0
		fi
	done
}

if [ "${CERT_RELOAD_WATCH:-false}" = "true" ]; then
	# $$ is this shell, which exec below turns into the radiusd process.
	watch_certificates "$$" &
fi

# -f keeps radiusd in the foreground; without it the container exits
# immediately. -l stdout keeps logging off the read-only filesystem.
set -- -f -l stdout -d /etc/raddb "$@"

if [ "${FREERADIUS_ENABLE_DEBUG:-false}" = "true" ]; then
	echo "entrypoint: WARNING debug mode logs inner-tunnel cleartext passwords" >&2
	set -- -X "$@"
fi

exec /opt/sbin/radiusd "$@"
```

- [ ] **Step 5: Write `freeradius/healthcheck.sh`**

```sh
#!/bin/sh
# Container healthcheck: prove radiusd is listening and processing packets,
# not merely that the process exists.
#
# radclient's exit status is the signal and MUST NOT be piped -- through tail
# or grep the shell reports the pipeline's status, which is always 0, giving a
# healthcheck that can never fail.
set -eu

secret_file=/run/radiusd/healthcheck.secret
[ -r "$secret_file" ] || exit 1

printf 'Message-Authenticator = 0x00\n' \
	| /opt/bin/radclient -q -t 2 -r 1 127.0.0.1:1812 status "$(cat "$secret_file")" \
	>/dev/null 2>&1
```

- [ ] **Step 6: Rewrite the `Dockerfile`**

```dockerfile
FROM freeradius/freeradius-server:3.2.10-alpine

LABEL org.opencontainers.image.title="authentik-freeradius" \
      org.opencontainers.image.description="FreeRADIUS EAP-TTLS front-end for the authentik RADIUS outpost (WPA2/3-Enterprise)" \
      org.opencontainers.image.source="https://github.com/wus-technik/authentik-freeradius"

# No openssl and no DH parameter generation: FreeRADIUS 3.2 configures DH
# itself, and radclient for the healthcheck already ships in the base image.

COPY freeradius/radiusd.conf /etc/raddb/radiusd.conf
COPY freeradius/clients.conf /etc/raddb/clients.conf
COPY freeradius/mods/eap /etc/raddb/mods-available/eap
COPY freeradius/sites/site /etc/raddb/sites-available/site
COPY freeradius/sites/proxy-inner-tunnel /etc/raddb/sites-available/proxy-inner-tunnel
COPY freeradius/entrypoint.sh /entrypoint.sh
COPY freeradius/healthcheck.sh /healthcheck.sh

RUN rm -f /etc/raddb/sites-enabled/* \
 && ln -s ../sites-available/site /etc/raddb/sites-enabled/site \
 && ln -s ../sites-available/proxy-inner-tunnel /etc/raddb/sites-enabled/proxy-inner-tunnel \
 && chmod +x /entrypoint.sh /healthcheck.sh \
 && mkdir -p /tmp/radiusd /run/radiusd

EXPOSE 1812/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD /healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 7: Delete the template**

```bash
git rm freeradius/clients.conf.template
```

- [ ] **Step 8: Verify the configuration parses**

```bash
docker build -t akfr-check .
docker run --rm \
  -e RADIUS_CLIENT_NET=10.0.0.0/8 \
  -e RADIUS_SECRET='se/cret&with\weird$chars' \
  -e RADIUS_HEALTHCHECK_SECRET=dummy \
  -e AUTHENTIK_RADIUS_HOST=127.0.0.1 \
  -e AUTHENTIK_RADIUS_SECRET='an/other&secret' \
  -e TLS_CERT_PATH=/tmp/c.pem -e TLS_KEY_PATH=/tmp/k.pem \
  --entrypoint sh akfr-check -c \
  'apk add --no-cache openssl >/dev/null 2>&1; openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=t -keyout /tmp/k.pem -out /tmp/c.pem >/dev/null 2>&1; /opt/sbin/radiusd -XC -d /etc/raddb'
```

Expected: ends with `Configuration appears to be OK`, and the output contains **no** line matching `dh_file`, `no longer necessary`, or `Failed resolving`.

**[verified]** This exact configuration — no `ca_file`, no `dh_file`, `tls_max_version = "1.2"`, `$ENV{}` paths — was run against FreeRADIUS 3.2.10 during planning. `-XC` passes clean and a full EAP-TTLS handshake completes (`SUCCESS`, MPPE keys OK). Omitting `ca_file` needs no fallback.

- [ ] **Step 9: Run the end-to-end test**

```bash
./test/e2e/run.sh
```

Expected: `PASS: all end-to-end checks succeeded`, with all four checks reporting `ok`. Check 3 (recovery) is the one that matters — if it fails, `status_check` is not `none`.

- [ ] **Step 10: Prove the regression test actually detects the fault**

A test that cannot fail is worthless. Break it deliberately and confirm the rig notices. The backup-and-restore shape matters: a bare `sed -i` leaves `clients.conf` broken if the run is interrupted, and that file is the one place where the fault is catastrophic.

```bash
cp freeradius/clients.conf freeradius/clients.conf.bak
sed 's/status_check = none/status_check = status-server/' \
    freeradius/clients.conf.bak > freeradius/clients.conf

if ./test/e2e/run.sh; then
	cp freeradius/clients.conf.bak freeradius/clients.conf
	rm -f freeradius/clients.conf.bak
	echo "REGRESSION TEST IS BROKEN: the suite passed with status_check=status-server" >&2
	exit 1
fi

cp freeradius/clients.conf.bak freeradius/clients.conf
rm -f freeradius/clients.conf.bak
grep -q 'status_check = none' freeradius/clients.conf || { echo "restore failed" >&2; exit 1; }
./test/e2e/run.sh
```

Expected: the first run **fails** at `== 3/4 recovery ==` with the "home server never revived" message; the final run passes. Do not skip this step, and confirm `git diff freeradius/clients.conf` is empty afterwards.

- [ ] **Step 11: Commit**

```bash
git add Dockerfile freeradius/
git commit -m "feat: rebuild the FreeRADIUS image and configuration

Replaces sed secret templating with FreeRADIUS \$ENV{} expansion, so
secrets stay in the environment instead of being written to disk and
values containing / & or \\ stop corrupting clients.conf.

Modernises the proxy configuration to home_server/home_server_pool with
status_check = none -- the authentik outpost never answers Status-Server,
so status checks would leave a dead home server dead forever.

Scopes the client to RADIUS_CLIENT_NET instead of 0.0.0.0/0, disables
OCSP stapling (Let's Encrypt retired OCSP in 2025), drops dh_file and the
openssl dependency (obsolete in FreeRADIUS 3.2), drops ca_file (it is the
client-cert trust set, not the server chain), and caps TLS at 1.2 for
supplicant compatibility.

Adds a Status-Server healthcheck and fail-fast environment validation.

Refs goauthentik/authentik#5328"
```

---

### Task 3: Repository cleanup

Remove the OpenLDAP lab this repository was forked from. `wpa2_supplicant.conf` stays until Task 6 moves its content into `docs/clients.md`.

**Files:**
- Delete: `environment/my-env.yaml`, `environment/my-env.startup.yaml`, `img/` (6 files), `docker-compose.yml.example`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Independent of every other task.

- [ ] **Step 1: Delete the stale files**

```bash
git rm -r environment img docker-compose.yml.example
```

`environment/` configures an OpenLDAP container that no longer exists in this stack; `img/` are screenshots of that lab's Windows dialogs; `docker-compose.yml.example` is superseded by the committed `docker-compose.yml` from Task 4.

- [ ] **Step 2: Rewrite `.gitignore`**

`docker-compose.yml` must stop being ignored — a Portainer git-backed stack cannot deploy a file that is not in the repository.

```
# The stack file is the deployable artifact and MUST be committed.
# Operator-specific values belong in .env or Portainer stack variables.
.env
docker-compose.override.yml
test/e2e/certs/
```

- [ ] **Step 3: Verify nothing references the deleted files**

```bash
grep -rn "environment/my-env\|img/\|docker-compose.yml.example" --exclude-dir=.git . || echo "no references"
```

Expected: matches only inside `README.md` (rewritten in Task 6) and `docs/superpowers/`. Any other match must be fixed now.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove OpenLDAP lab leftovers and unignore the stack file

environment/ configured an OpenLDAP container that is not part of this
stack, and img/ were screenshots of that lab. docker-compose.yml is now
committed as the deployable artifact for the Portainer git stack."
```

---

### Task 4: Deployable stack

**Files:**
- Create: `docker-compose.yml`
- Create: `docker-compose.override.yml.example`
- Create: `.env.example`

**Interfaces:**
- Consumes: the image and environment-variable contract from Task 2.
- Produces: a `freeradius` service published on `1812/udp` and an `authentik_radius` service reachable at that hostname on the `radius` network.

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
#  Deployable stack for WPA2/3-Enterprise authentication against authentik.
#
#  UniFi AP --EAP-TTLS--> freeradius --inner PAP--> authentik_radius --> authentik
#
#  Deployed as a Portainer git-backed stack: set the variables from
#  .env.example in Portainer's stack environment section.
#
#  No "version:" key -- it is obsolete in Compose v2 and only emits a warning.

services:
  authentik_radius:
    image: ghcr.io/goauthentik/radius:${AUTHENTIK_VERSION:?set AUTHENTIK_VERSION to match your authentik server}
    restart: unless-stopped
    environment:
      AUTHENTIK_HOST: ${AUTHENTIK_HOST:?set AUTHENTIK_HOST}
      AUTHENTIK_TOKEN: ${AUTHENTIK_TOKEN:?set AUTHENTIK_TOKEN}
      AUTHENTIK_INSECURE: ${AUTHENTIK_INSECURE:-false}
      AUTHENTIK_LISTEN__METRICS: 0.0.0.0:9300
    #  No healthcheck override. The image already ships
    #  HEALTHCHECK ["CMD","/radius","healthcheck"] with a 5s interval and 20
    #  retries, maintained upstream. Verified: it exits 1 while the outpost
    #  cannot reach authentik and its metrics port is closed, which is exactly
    #  the condition depends_on must wait through.
    networks: [radius]
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  freeradius:
    image: ghcr.io/wus-technik/authentik-freeradius:${IMAGE_TAG:-latest}
    restart: unless-stopped
    depends_on:
      authentik_radius:
        condition: service_healthy
    environment:
      AUTHENTIK_RADIUS_HOST: authentik_radius
      AUTHENTIK_RADIUS_SECRET: ${AUTHENTIK_RADIUS_SECRET:?set AUTHENTIK_RADIUS_SECRET}
      RADIUS_SECRET: ${RADIUS_SECRET:?set RADIUS_SECRET}
      RADIUS_CLIENT_NET: ${RADIUS_CLIENT_NET:?set RADIUS_CLIENT_NET to your AP subnet}
      TLS_CERT_PATH: ${TLS_CERT_PATH:?set TLS_CERT_PATH}
      TLS_KEY_PATH: ${TLS_KEY_PATH:?set TLS_KEY_PATH}
      CERT_RELOAD_WATCH: ${CERT_RELOAD_WATCH:-false}
      CERT_RELOAD_INTERVAL: ${CERT_RELOAD_INTERVAL:-3600}
      FREERADIUS_ENABLE_DEBUG: ${FREERADIUS_ENABLE_DEBUG:-false}
    volumes:
      #  The whole tree, read-only. certbot repoints live/ symlinks at new
      #  archive/ files, so mounting the individual pem files pins the old
      #  inode and the container serves a stale certificate forever.
      - ${LETSENCRYPT_DIR:-/etc/letsencrypt}:/etc/letsencrypt:ro
    ports:
      - "${RADIUS_LISTEN_ADDR:-0.0.0.0}:1812:1812/udp"
    read_only: true
    #  /var/run is a symlink to ../run in the Alpine image, so radiusd's
    #  run_dir = /var/run/radiusd resolves to /run/radiusd. Verified: these two
    #  tmpfs mounts are sufficient and a third on /var/run is redundant.
    tmpfs:
      - /run/radiusd
      - /tmp/radiusd
    cap_drop: [ALL]
    networks: [radius]
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

networks:
  radius:
    driver: bridge
```

- [ ] **Step 2: Write `.env.example`**

```sh
#  Copy to .env, or paste these into Portainer's stack environment variables.
#  Never commit a filled-in .env -- .gitignore excludes it.

#  --- images ---------------------------------------------------------------
#  Must match your authentik server version.
AUTHENTIK_VERSION=2026.2.1
#  Tag of ghcr.io/wus-technik/authentik-freeradius.
IMAGE_TAG=latest

#  --- authentik ------------------------------------------------------------
AUTHENTIK_HOST=https://auth.example.com
#  Outpost token from authentik.
AUTHENTIK_TOKEN=
#  Set true only if authentik uses a certificate the outpost cannot verify.
AUTHENTIK_INSECURE=false

#  --- RADIUS secrets -------------------------------------------------------
#  Between FreeRADIUS and the outpost. Must equal the shared secret configured
#  on the RADIUS provider in authentik. Generate with: openssl rand -hex 32
AUTHENTIK_RADIUS_SECRET=
#  Between the UniFi APs and FreeRADIUS. Enter this in the UniFi RADIUS
#  profile. Generate with: openssl rand -hex 32
RADIUS_SECRET=

#  --- network --------------------------------------------------------------
#  CIDR of the APs/controller allowed to send requests. Never 0.0.0.0/0.
RADIUS_CLIENT_NET=10.0.0.0/8
#  Bind address for the published UDP port.
RADIUS_LISTEN_ADDR=0.0.0.0

#  --- TLS ------------------------------------------------------------------
#  Host directory mounted read-only at /etc/letsencrypt in the container.
LETSENCRYPT_DIR=/etc/letsencrypt
#  CONTAINER paths, i.e. under /etc/letsencrypt.
TLS_CERT_PATH=/etc/letsencrypt/live/radius.example.com/fullchain.pem
TLS_KEY_PATH=/etc/letsencrypt/live/radius.example.com/privkey.pem
#  Restart the container when the certificate changes, so renewals take
#  effect. Costs a few seconds of authentication downtime per renewal.
CERT_RELOAD_WATCH=true
CERT_RELOAD_INTERVAL=3600

#  --- debugging ------------------------------------------------------------
#  DEVELOPMENT ONLY. -X logs the inner tunnel, including cleartext passwords.
FREERADIUS_ENABLE_DEBUG=false
```

- [ ] **Step 3: Write `docker-compose.override.yml.example`**

```yaml
#  Local development: build the image from source instead of pulling it.
#  Copy to docker-compose.override.yml (gitignored); Compose merges it
#  automatically.
services:
  freeradius:
    build:
      context: .
      dockerfile: Dockerfile
    image: authentik-freeradius:dev
```

- [ ] **Step 4: Verify the stack file is valid and the guards fire**

```bash
cp .env.example .env
docker compose config -q && echo "compose config OK"
```

Expected: `compose config OK` with no warning about an obsolete `version` key.

Then confirm a missing required variable is caught rather than silently defaulted:

```bash
( grep -v '^RADIUS_CLIENT_NET' .env > .env.broken && docker compose --env-file .env.broken config -q ) 2>&1 | tail -2
rm -f .env.broken
```

Expected: an error naming `RADIUS_CLIENT_NET` and the message `set RADIUS_CLIENT_NET to your AP subnet`.

- [ ] **Step 5: Clean up the local env file**

```bash
rm -f .env
git status --short
```

Expected: `.env` does not appear — `.gitignore` from Task 3 covers it.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml docker-compose.override.yml.example .env.example
git commit -m "feat: add Portainer-deployable compose stack

Image-based with no build context so a git-backed Portainer stack can
pull and run it. Mounts the whole letsencrypt tree read-only rather than
individual pem files, because certbot repoints the live/ symlinks and a
file mount would pin the stale inode.

Runs FreeRADIUS read-only with all capabilities dropped; UDP 1812 needs
no CAP_NET_BIND_SERVICE."
```

---

### Task 5: GitHub Actions build pipeline

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: the root `Dockerfile` from Task 2 and `test/e2e/run.sh` from Task 1.
- Produces: `ghcr.io/wus-technik/authentik-freeradius` tagged by branch, semver, and short SHA, with `latest` on `main`.

- [ ] **Step 1: Write the workflow**

```yaml
name: build

on:
  push:
    branches: [develop, main]
    tags: ['v*']
  pull_request:
    branches: [develop, main]
  schedule:
    #  Weekly, to pick up base-image security fixes.
    - cron: '17 4 * * 1'
  workflow_dispatch:

env:
  IMAGE: ghcr.io/${{ github.repository }}

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Lint the Dockerfile
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile

      - name: Lint the shell scripts
        run: |
          sudo apt-get update && sudo apt-get install -y shellcheck
          shellcheck freeradius/entrypoint.sh freeradius/healthcheck.sh \
                     test/e2e/client/auth.sh test/e2e/run.sh

  validate:
    #  Configuration syntax gate. Necessary but NOT sufficient -- radiusd -XC
    #  happily accepts a status_check setting that permanently breaks
    #  authentication, which is why the e2e job exists.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-buildx-action@v4

      - name: Build the image for testing
        uses: docker/build-push-action@v7
        with:
          context: .
          load: true
          tags: akfr:ci
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Check the FreeRADIUS configuration
        run: |
          #  The default runner shell is `bash -e` WITHOUT pipefail, so the
          #  `| tee` below would otherwise mask a non-zero radiusd exit.
          set -euo pipefail
          openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -subj '/CN=radius.ci.test' -keyout key.pem -out cert.pem
          docker run --rm \
            -v "$PWD/cert.pem:/certs/cert.pem:ro" \
            -v "$PWD/key.pem:/certs/key.pem:ro" \
            -e RADIUS_CLIENT_NET=10.0.0.0/8 \
            -e RADIUS_SECRET='se/cret&with\weird$chars' \
            -e RADIUS_HEALTHCHECK_SECRET=dummy \
            -e AUTHENTIK_RADIUS_HOST=127.0.0.1 \
            -e AUTHENTIK_RADIUS_SECRET='an/other&secret' \
            -e TLS_CERT_PATH=/certs/cert.pem \
            -e TLS_KEY_PATH=/certs/key.pem \
            --entrypoint /opt/sbin/radiusd \
            akfr:ci -XC -d /etc/raddb 2>&1 | tee radiusd.log
          grep -q 'Configuration appears to be OK' radiusd.log
          ! grep -qiE 'no longer necessary|Failed resolving' radiusd.log

  e2e:
    #  The behavioural gate. Catches faults radiusd -XC cannot see.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run the end-to-end suite
        run: ./test/e2e/run.sh

  build:
    needs: [lint, validate, e2e]
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      attestations: write
      id-token: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-qemu-action@v4

      - uses: docker/setup-buildx-action@v4

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v6
        with:
          images: ${{ env.IMAGE }}
          tags: |
            type=ref,event=branch
            type=ref,event=pr
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,format=short
            type=raw,value=latest,enable={{is_default_branch}}

      - id: push
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true
          sbom: true
```

Note on `type=raw,value=latest,enable={{is_default_branch}}`: **confirmed and intended.** The repository's default branch is `develop`, so `latest` tracks `develop`. Leave this line as written — do not change it to `main`. The compose file's `IMAGE_TAG` defaults to `latest`, so a deployed stack follows `develop`; pin `IMAGE_TAG` to a semver tag in Portainer for anything you do not want moving.

- [ ] **Step 2: Verify the workflow parses**

```bash
command -v actionlint >/dev/null && actionlint .github/workflows/build.yml || \
  python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); print('YAML OK')"
```

Expected: no errors.

- [ ] **Step 3: Confirm every action major still targets node24**

```bash
for spec in actions/checkout:v7 docker/setup-qemu-action:v4 docker/setup-buildx-action:v4 \
            docker/login-action:v4 docker/metadata-action:v6 docker/build-push-action:v7; do
  repo=${spec%:*}; ref=${spec#*:}
  echo "$repo@$ref -> $(gh api "repos/$repo/contents/action.yml?ref=$ref" --jq .content | base64 -d | grep -E '^\s+using:' | head -1)"
done
```

Expected: every line reports `node24`. If any does not, find a newer major rather than accepting node20.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build and publish the image to GHCR

Four gates: hadolint and shellcheck, a radiusd -XC configuration check,
the end-to-end EAP-TTLS suite, then a multi-arch build with provenance
and SBOM attestations.

The e2e job is not redundant with -XC: a configuration that permanently
breaks authentication after an outpost restart passes the syntax check
cleanly.

All actions pinned to majors declaring node24."
```

- [ ] **Step 5: Verify the pipeline on a real run**

```bash
git push
gh run watch --exit-status
```

Expected: all four jobs pass. If `build` fails on GHCR permissions, the package needs to be created by the first successful push; check `gh api user/packages/container/authentik-freeradius` afterwards and set the package visibility to public so Portainer needs no registry credentials.

---

### Task 6: Documentation

**Files:**
- Rewrite: `README.md`
- Create: `docs/authentik.md`, `docs/unifi.md`, `docs/clients.md`, `docs/troubleshooting.md`
- Delete: `wpa2_supplicant.conf`

**Interfaces:**
- Consumes: variable names from Task 4's `.env.example`.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Rewrite `README.md`**

Replace the entire file. It currently documents the unrelated OpenLDAP lab, including the line "This is for lab use only. **Not secure at all.**", which is actively misleading for a production stack.

````markdown
# authentik-freeradius

WPA2/WPA3-Enterprise WiFi authentication against [authentik](https://goauthentik.io),
for UniFi access points.

## Why this exists

authentik's RADIUS outpost speaks **PAP only**. Every 802.1X supplicant speaks **EAP**.
authentik will not implement MSCHAPv2 (it requires reversible password storage), and the
EAP-TLS support that eventually landed depends on the MTLS stage and is
**enterprise-licensed**. See [goauthentik/authentik#5328](https://github.com/goauthentik/authentik/issues/5328).

So FreeRADIUS goes in front. It owns the server certificate, terminates the EAP-TTLS
tunnel from the access points, unwraps the inner PAP exchange, and proxies that to the
authentik outpost as an ordinary RADIUS Access-Request:

```
UniFi AP ──EAP-TTLS (802.1X, RADIUS/UDP 1812)──▶ FreeRADIUS
                                                    │  terminates the TLS tunnel,
                                                    │  unwraps the inner PAP exchange
                                                    ▼
                                          authentik RADIUS outpost  ──HTTP──▶ authentik
                                          (plain PAP, RADIUS/UDP 1812)
```

## Security properties — read before deploying

This design is a workaround, and it has a real cost:

- **FreeRADIUS sees every user's cleartext password.** EAP-TTLS/PAP means the inner
  exchange is a plaintext password, decrypted by this container.
- **It is forwarded to the outpost as PAP.** RADIUS shared-secret obfuscation is not
  transport security.

Therefore: keep both containers on a private Docker network on a trusted host, never
publish the outpost's RADIUS port, and use long random shared secrets
(`openssl rand -hex 32`). Anyone who compromises this host can read staff passwords.

`FREERADIUS_ENABLE_DEBUG=true` logs the inner tunnel, cleartext passwords included. It is
for development only.

## Quickstart (Portainer git-backed stack)

1. Point a Portainer stack at this repository, `docker-compose.yml`.
2. Fill in the stack environment variables from [`.env.example`](.env.example).
3. Make sure the host has a certificate for the RADIUS server name and that
   `LETSENCRYPT_DIR` is readable by Docker.
4. Deploy, then follow [docs/authentik.md](docs/authentik.md) and
   [docs/unifi.md](docs/unifi.md).

Certificate renewals need `CERT_RELOAD_WATCH=true`: FreeRADIUS reads TLS material once at
startup, so without it the container serves the old certificate until someone restarts it.

## Documentation

- [docs/authentik.md](docs/authentik.md) — provider, outpost and token
- [docs/unifi.md](docs/unifi.md) — RADIUS profile and SSID
- [docs/clients.md](docs/clients.md) — Windows, Android, iOS, Linux
- [docs/troubleshooting.md](docs/troubleshooting.md) — when it does not work

## Development

```bash
cp docker-compose.override.yml.example docker-compose.override.yml   # build from source
./test/e2e/run.sh                                                    # end-to-end suite
```

`test/e2e/run.sh` drives a real EAP-TTLS exchange with `eapol_test` against a stand-in
outpost, including an outage/recovery cycle. Run it before every push — a `radiusd -XC`
syntax check alone does **not** catch the failure modes that matter here.

## Not implemented

- [RADIUS accounting (UDP 1813)](../../issues) — UniFi accounting records are not handled.
- [Dynamic VLAN per user/group](../../issues) — no `Tunnel-Private-Group-Id` mapping yet.
````

- [ ] **Step 2: Write `docs/authentik.md`**

```markdown
# authentik configuration

## 1. RADIUS provider

**Applications → Providers → Create → RADIUS Provider.**

| Field | Value |
|---|---|
| Name | `radius-wifi` |
| Authorization flow | an explicit-consent-free flow, e.g. `default-authentication-flow` |
| Client Networks | the Docker network the FreeRADIUS container sits on, e.g. `172.16.0.0/12` |
| Shared secret | the value of `AUTHENTIK_RADIUS_SECRET` |

The shared secret **must** match `AUTHENTIK_RADIUS_SECRET` in the stack exactly. A mismatch
shows up as `No provider found` with a `hashed_secret` field in the outpost log.

Client Networks refers to the FreeRADIUS container's address, not the access points'. The
APs never talk to authentik directly.

## 2. Application

Create an application and bind it to the provider. Bind policies or groups here to control
who may join the WiFi.

## 3. Outpost

**Applications → Outposts → Create.** Type **RADIUS**, assign the application, and copy the
token into `AUTHENTIK_TOKEN`.

If authentik has Docker socket integration enabled it will try to manage its own outpost
container. This stack runs the outpost itself, so use an outpost with no service connection
and let Compose own the container.

## 4. Flow requirements

The flow must complete without user interaction — no MFA prompt, no consent stage. RADIUS
carries a username and a password and nothing else. A flow requiring anything more fails
with `flow error` in the outpost log.
```

- [ ] **Step 3: Write `docs/unifi.md`**

```markdown
# UniFi configuration

## RADIUS profile

**Settings → Profiles → RADIUS → Create New.**

| Field | Value |
|---|---|
| Name | `authentik` |
| Authentication Server IP | the Docker host running this stack |
| Authentication Server Port | `1812` |
| Authentication Server Secret | `RADIUS_SECRET` |

Leave the accounting server empty. This stack does not implement accounting; UniFi
accounting records would time out.

Do not enable **RADIUS Assigned VLAN** — dynamic VLAN is not implemented yet.

## SSID

**Settings → WiFi → Create New.**

| Field | Value |
|---|---|
| Security Protocol | `WPA2 Enterprise` (or `WPA3 Enterprise` / `WPA2/WPA3` if all clients support it) |
| RADIUS Profile | `authentik` |

WPA3-Enterprise requires Protected Management Frames and is not supported by older clients.
Start with WPA2 Enterprise, confirm it works, then move up.

## Firewall

The APs must reach the Docker host on **UDP 1812**. `RADIUS_CLIENT_NET` must cover the AP
and controller addresses, or FreeRADIUS drops the packets as coming from an unknown client
— visible in the log as `Ignoring request ... from unknown client`.
```

- [ ] **Step 4: Write `docs/clients.md`**

This absorbs the content of `wpa2_supplicant.conf`, with the lab credentials replaced.

````markdown
# Client configuration

All clients use **EAP-TTLS** with **PAP** as the inner method.

## The certificate trust problem

A publicly-trusted certificate (Let's Encrypt) means clients already trust the issuer, but
that is **not** the same as being safe. Unless the client is told which CA and which server
name to expect, it will accept any server presenting any valid certificate — which is
exactly how EAP credential-theft attacks work.

Configure the CA **and** the server name on every managed device, via Intune, GPO or an
`.mobileconfig`. This stack cannot enforce it from the server side.

## Windows 10/11

Network & Internet → Manage known networks → Add.

- Security type: **WPA2-Enterprise**
- EAP method: **EAP-TTLS**
- Trusted Root CA: the CA that issued the server certificate
- Server name: the certificate's CN, e.g. `radius.example.com`
- Authentication method: **Unencrypted password (PAP)**

Windows does not offer EAP-TTLS/PAP in every UI path; deploy it by GPO or Intune profile
for a fleet.

## Android 11+

- EAP method: **TTLS**
- Phase 2: **PAP**
- CA certificate: **Use system certificates** (not "Do not validate")
- Domain: `radius.example.com` — mandatory on Android 11+; the network will not connect
  without it

## iOS / macOS

iOS has no EAP-TTLS/PAP option in the manual UI. Deploy a `.mobileconfig` profile with
Apple Configurator or your MDM, setting EAP-TTLS, inner authentication PAP, and the trusted
certificate and server name.

## Linux (NetworkManager)

- Security: **WPA & WPA2 Enterprise**
- Authentication: **Tunneled TLS**
- CA certificate: the issuing CA
- Inner authentication: **PAP**

## Linux (wpa_supplicant)

```
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=root
network={
	ssid="YOUR-SSID"
	scan_ssid=1
	key_mgmt=WPA-EAP
	eap=TTLS
	identity="user@example.com"
	password="user-password"
	anonymous_identity="anonymous"
	ca_cert="/etc/ssl/certs/ca-certificates.crt"
	domain_suffix_match="radius.example.com"
	phase2="auth=PAP"
}
```

Run with `sudo wpa_supplicant -d -c ./wpa2_supplicant.conf -i wlan0`.

Do not omit `ca_cert` and `domain_suffix_match`. Without them the supplicant accepts any
server and will hand the password to an impostor access point.
````

- [ ] **Step 5: Write `docs/troubleshooting.md`**

````markdown
# Troubleshooting

Work from the outside in: supplicant → AP → FreeRADIUS → outpost → authentik.

## Test the whole chain without a WiFi client

`eapol_test` (from `wpa_supplicant`) drives a real EAP-TTLS exchange. Unlike `radtest`, it
exercises the actual EAP path.

```bash
./test/e2e/run.sh
```

## Test only the outpost half

```bash
docker compose exec freeradius sh -c \
  'printf "User-Name=%s\nUser-Password=%s\n" someuser somepass | \
   radclient -x authentik_radius:1812 auth "$AUTHENTIK_RADIUS_SECRET"'
```

Access-Accept means authentik and the outpost are fine and the problem is in the EAP half.

## Symptoms

**`Ignoring request ... from unknown client`** — the AP's address is outside
`RADIUS_CLIENT_NET`.

**`Received packet ... with invalid Message-Authenticator! (Shared secret is incorrect.)`**
— `RADIUS_SECRET` does not match the UniFi RADIUS profile.

**`No provider found` with `hashed_secret` in the outpost log** — `AUTHENTIK_RADIUS_SECRET`
does not match the shared secret on authentik's RADIUS provider.

**Client connects then immediately drops** — usually certificate trust. Check the client
trusts the issuing CA and that the configured server name matches the certificate CN.

**Everything worked, then stopped after an authentik restart, and never recovered** —
check `status_check = none` in `freeradius/clients.conf`. The authentik outpost does not
answer RFC 5997 Status-Server, so `status_check = status-server` leaves a dead home server
dead permanently. Confirm with:

```bash
docker compose logs freeradius | grep -iE 'zombie|dead|alive'
```

`Marking home server ... as dead.` with no later `alive again` is this fault.

**Authentication stopped working weeks after deployment** — the certificate was renewed and
the container is still serving the old one. Set `CERT_RELOAD_WATCH=true`, and confirm
`LETSENCRYPT_DIR` mounts the whole tree rather than individual `.pem` files: certbot
repoints the `live/` symlinks, so a file mount pins the old inode.

## Debug logging

```bash
FREERADIUS_ENABLE_DEBUG=true docker compose up freeradius
```

**This logs cleartext passwords.** Development only; never leave it on.

## Client compatibility

The server caps TLS at 1.2 deliberately — FreeRADIUS 3.2 advises against TLS 1.3 for EAP
because supplicant support is uneven. If you raise `tls_max_version` to `"1.3"`, retest
Windows, Android, iOS and Linux before rolling out.
````

- [ ] **Step 6: Delete the lab supplicant file**

```bash
git rm wpa2_supplicant.conf
```

Its content now lives in `docs/clients.md` with the lab credentials replaced and the
missing `ca_cert` / `domain_suffix_match` lines added.

- [ ] **Step 7: Verify no stale references remain**

```bash
grep -rniE 'tknv|awas\.lab|symbol123|openldap|not secure at all' \
  --exclude-dir=.git --exclude-dir=superpowers . || echo "clean"
```

Expected: `clean`. Anything found is a leftover from the fork.

- [ ] **Step 8: Commit**

```bash
git add -A README.md docs wpa2_supplicant.conf
git commit -m "docs: rewrite for the actual project

Replaces documentation of the OpenLDAP lab this repository was forked
from, which still told readers the setup was 'not secure at all'.

Documents why the FreeRADIUS detour is necessary, the credential
exposure inherent to EAP-TTLS/PAP, authentik and UniFi setup, per-platform
client configuration including the CA/server-name pinning that a public
certificate does not remove, and the failure modes worth recognising.

Refs goauthentik/authentik#5328"
```

---

### Task 7: File the deferred work

**Files:** none — this task creates GitHub issues.

**Interfaces:**
- Consumes: nothing.
- Produces: two issue numbers to reference from the README's "Not implemented" section.

- [ ] **Step 1: Open the accounting issue**

```bash
gh issue create --repo wus-technik/authentik-freeradius \
  --title "Support RADIUS accounting (UDP 1813)" \
  --body "UniFi sends Accounting-Request start/stop/interim records when accounting is
enabled on the RADIUS profile. This stack has no \`type = acct\` listener and does not
publish 1813, so those requests time out. \`docs/unifi.md\` currently tells operators to
leave the accounting server empty.

## Needed

- An \`acct\` listener in \`freeradius/sites/site\`, plus an \`accounting\` section.
- Publish \`1813/udp\` in \`docker-compose.yml\`.
- A decision on where records go: proxied to authentik, written locally, or discarded.
  The authentik outpost handles only Access-Request (\`ServeRADIUS\` has no else branch),
  so proxying accounting to it will not work as-is.
- An end-to-end case in \`test/e2e/run.sh\` using \`radclient ... acct\`.

## Notes

\`clients.conf\` sets \`require_message_authenticator = yes\` on the uplink client. That is
safe for EAP but Accounting-Requests do not carry Message-Authenticator, so this will need
revisiting.

Deferred from the stack design: \`docs/superpowers/specs/2026-09-01-authentik-freeradius-stack-design.md\` section 7."
```

- [ ] **Step 2: Open the dynamic VLAN issue**

```bash
gh issue create --repo wus-technik/authentik-freeradius \
  --title "Support dynamic VLAN assignment per user/group" \
  --body "Place users into VLANs based on authentik group membership, so that the WiFi can
separate staff, guests and devices without separate SSIDs.

## Mechanism

authentik returns \`Tunnel-Type\`, \`Tunnel-Medium-Type\` and \`Tunnel-Private-Group-Id\`
from RADIUS property mappings. \`use_tunneled_reply = yes\` (already set in
\`freeradius/mods/eap\`) copies inner-tunnel reply attributes to the outer Access-Accept
that the AP acts on, which is the transport this needs.

## Needed

- RADIUS property mappings in authentik, bound to groups.
- Prefer a narrow \`update outer.session-state { ... }\` over relying on
  \`use_tunneled_reply\`, which copies *all* inner reply attributes outward.
- Enable **RADIUS Assigned VLAN** on the UniFi RADIUS profile and update \`docs/unifi.md\`.
- An end-to-end case asserting the attributes reach the outer Access-Accept.

## Blockers to check first

goauthentik/authentik#16980 and goauthentik/authentik#16993 were reported as obstructing
this. Verify their current status before starting.

## Background

Requested repeatedly in goauthentik/authentik#5328 (koalaeagle 2023-05-20, KautzA
2023-05-24, cheggerdev 2025-04-23).

Deferred from the stack design: \`docs/superpowers/specs/2026-09-01-authentik-freeradius-stack-design.md\` section 7."
```

- [ ] **Step 3: Link the issues from the README**

Replace the `## Not implemented` section written in Task 6 with the real issue numbers
returned by the two commands above:

```markdown
## Not implemented

- RADIUS accounting (UDP 1813) — #<accounting issue number>
- Dynamic VLAN per user/group — #<vlan issue number>
```

- [ ] **Step 4: Verify and commit**

```bash
gh issue list --repo wus-technik/authentik-freeradius --limit 5
git add README.md
git commit -m "docs: link the deferred-work issues from the README"
```

---

## Final verification

- [ ] **Full suite passes from a clean checkout**

```bash
git clean -xdn                     # review what would be removed
docker compose --env-file .env.example config -q   # --env-file is a ROOT flag
./test/e2e/run.sh
```

Expected: `PASS: all end-to-end checks succeeded`.

- [ ] **The regression test still detects the critical fault**

Repeat Task 2 Step 10. If flipping `status_check` to `status-server` no longer fails the
suite, the suite has rotted and the most dangerous fault in this system is unguarded.

- [ ] **CI is green**

```bash
gh run list --limit 1
```

- [ ] **No secrets were committed**

```bash
git log -p --all -- . ':(exclude).env.example' \
  | grep -inE 'AUTHENTIK_TOKEN=.+|(^|_)RADIUS_SECRET=.{8,}'
```

Expected: no output. Excluding by pathspec rather than filtering lines containing the word "example" avoids both false positives and, more importantly, false negatives.
