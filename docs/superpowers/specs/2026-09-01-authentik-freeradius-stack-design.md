# Design: Deployable authentik + FreeRADIUS stack for WPA2/3-Enterprise

Date: 2026-09-01
Status: Approved (design), pending implementation plan
Repository: `wus-technik/authentik-freeradius` (public)

## 1. Problem and background

We need WPA2/WPA3-Enterprise WiFi authentication for our clients. The access points are
UniFi APs managed by a UniFi controller; the identity provider is authentik.

authentik cannot do this on its own. Its RADIUS outpost speaks **PAP only**. UniFi (like
every 802.1X supplicant) speaks **EAP**. The gap is documented at length in
[goauthentik/authentik#5328](https://github.com/goauthentik/authentik/issues/5328):

- BeryJu (authentik maintainer, 2023-07-11): MSCHAPv2 will not be implemented, because it
  requires plaintext or MD4-reversible password storage.
- The Go RADIUS library the outpost uses had no certificate handling, so EAP-TLS was not
  feasible for a long time.
- EAP-TLS eventually landed via PR #15702, which closed the issue — but it depends on the
  MTLS stage and is therefore **enterprise-licensed** (BeryJu, 2025-09-24). It is not
  available to us.

The workaround the thread converges on (jesusdf 2024-11-27, JuniorJPDJ 2025-04-21,
perillamint 2026-03-17) is to put FreeRADIUS in front:

```
UniFi AP ──EAP-TTLS (802.1X, RADIUS/UDP 1812)──▶ FreeRADIUS
                                                    │  terminates the TLS tunnel,
                                                    │  unwraps the inner PAP exchange
                                                    ▼
                                          authentik RADIUS outpost  ──HTTP──▶ authentik
                                          (plain PAP, RADIUS/UDP 1812)
```

FreeRADIUS owns the EAP-TTLS tunnel and the server certificate; authentik never sees EAP.
The inner PAP request is proxied to the outpost as an ordinary RADIUS Access-Request.

This repository already implements that flow correctly (commit `e693cb0`). What it is not
is deployable, maintainable, or free of latent faults. This design fixes that.

## 2. Goals

1. Fix the defects found in the current configuration (section 4).
2. Turn the repository into a **Portainer git-backed stack** that deploys by pulling a
   pre-built image.
3. Build and publish that image from **GitHub Actions** to GHCR.
4. Replace the stale documentation, which still describes the unrelated OpenLDAP lab this
   repository was forked from.

## 3. Non-goals

Explicitly out of scope for this work, by decision on 2026-09-01:

- **Zabbix monitoring.** Dropped for now; will be designed separately.
- **RADIUS accounting (UDP 1813).** Filed as a GitHub issue instead.
- **Dynamic VLAN assignment per user/group.** Filed as a GitHub issue instead.
- MAC-based authentication (MAB) for non-802.1X devices.
- Kubernetes/Helm packaging.
- EAP-TLS / client-certificate authentication.

## 4. Defects in the current implementation

Each of these is fixed by this design. Ordered by severity.

### 4.1 OCSP stapling against Let's Encrypt certificates (`freeradius/mods/eap`)

```
staple { enable = yes }
ocsp   { enable = yes  lifetime = 24  override_cert_url = no }
```

`staple` makes FreeRADIUS fetch an OCSP response for **its own** server certificate and
staple it into the TLS handshake, using the OCSP URL embedded in the certificate.
Let's Encrypt stopped including OCSP URLs in issued certificates in early 2025 and shut
down its OCSP responders in August 2025. With the LE certificate the compose example
mounts, there is no URL to fetch from and stapling cannot succeed.

The `ocsp` block is a separate mechanism: it validates **client** certificates. EAP-TTLS
with inner PAP presents no client certificate, so today it never runs — but it is a live
trap the moment anyone enables client certificates.

**Fix:** `staple { enable = no }` and `ocsp { enable = no }`.

### 4.2 CRL checking with no client certificates (`freeradius/mods/eap`)

`check_crl = yes` and `check_all_crl = yes` likewise apply to client certificate chains.
Unused today, and they would require a maintained CRL to be present on disk. **Fix:**
remove both.

### 4.3 Secret injection corrupts config (`freeradius/entrypoint.sh`)

```sh
sed "s/__AUTHENTIK_RADIUS_SECRET__/${AUTHENTIK_RADIUS_SECRET}/g"
```

Any secret containing `/`, `&`, or `\` produces a malformed or wrongly-valued
`clients.conf`. `/` in particular makes `sed` fail outright. The symptom is a generic
authentication failure with no obvious cause. The rendered file also persists both
plaintext secrets on the container filesystem.

**Fix:** FreeRADIUS 3 supports `$ENV{VAR}` expansion directly in configuration files (the
approach JuniorJPDJ uses in #5328). Secrets are referenced as `$ENV{RADIUS_SECRET}` and
`$ENV{AUTHENTIK_RADIUS_SECRET}`, read from the process environment at startup. The
template and the `sed` pipeline are deleted; no secret is ever written to disk.

### 4.4 RADIUS server open to the world (`freeradius/clients.conf.template`)

```
client client { ipaddr = 0.0.0.0/0  secret = "..." }
```

Any host that can reach UDP 1812 may attempt authentication, subject only to the shared
secret. **Fix:** `ipaddr = $ENV{RADIUS_CLIENT_NET}`, a required variable set to the AP /
controller subnet. No default that permits the internet.

### 4.5 POSIX violation (`freeradius/entrypoint.sh`)

`[ "${FREERADIUS_ENABLE_DEBUG}" == "true" ]` — `==` is not POSIX `test`. BusyBox `ash`
tolerates it; `dash` and strict shells do not. **Fix:** `=`.

### 4.6 Certificates are never reloaded

FreeRADIUS reads TLS material once at startup. After every Let's Encrypt renewal the
container keeps serving the previous certificate until someone restarts it — silently,
until the old certificate expires and every client fails at once. SIGHUP does not
reliably reload TLS material in FreeRADIUS 3.

**Fix:** an opt-in watcher (section 5.4) that terminates the process on certificate
change, letting the container's restart policy bring it back with the new material.

### 4.7 Deprecated proxy syntax (`freeradius/clients.conf.template`)

```
realm authentik { type = radius  authhost = authentik_radius:1812  secret = "..."  nostrip }
```

The `authhost` form is FreeRADIUS 2 syntax, deprecated in 3.x. Besides deprecation, it
gives no home-server health checking: if the authentik outpost dies, requests are
blackholed rather than failed fast.

**Fix:** `home_server` / `home_server_pool` / `realm … auth_pool` with `status_check`,
`response_window` and `revive_interval`.

### 4.8 Non-reproducible, unpinned image build (`Dockerfile`)

- `FROM freeradius/freeradius-server:latest-3.2-alpine` — floating tag.
- `RUN openssl dhparam -out dh.pem 2048` — searches for a random safe prime on every
  build. Slow (minutes) and produces different output every time.
- `RUN wget -O /etc/ca.crt https://ccadb.my.salesforce-sites.com/...` — a build-time
  network fetch of the entire Mozilla root store from a URL we do not control.

**Fix:** pin `3.2.10-alpine`; generate DH parameters from the RFC 7919 named group
`ffdhe2048` (deterministic and instant, no prime search); use Alpine's own
`ca-certificates` bundle.

### 4.9 `proxy_requests` left implicit (`freeradius/radiusd.conf`)

The configuration relies on proxying but never states `proxy_requests = yes`. It works
today by default; it should not be load-bearing on a default. **Fix:** set it explicitly.

### 4.10 Repository is not deployable

`docker-compose.yml` is in `.gitignore`, so the repository ships no deployable artifact —
only an example that builds the image locally. A Portainer git-backed stack cannot use it.

### 4.11 Stale content

`README.md` documents the OpenLDAP/EAP-TTLS lab this repository was forked from: user
`tknv`, LDAP bootstrap LDIFs, "This is for lab use only. **Not secure at all.**". The
`environment/*.yaml` files configure an OpenLDAP container that no longer exists, `img/`
holds screenshots of it, and `wpa2_supplicant.conf` carries lab credentials.

## 5. Design

### 5.1 Repository layout

```
.github/workflows/build.yml            CI: validate, build, publish
Dockerfile
docker-compose.yml                     committed; the Portainer stack entry point
docker-compose.override.yml.example    local development (build from source)
.env.example                           every variable, documented
freeradius/
  radiusd.conf
  clients.conf                         static; $ENV{} references, no template
  entrypoint.sh
  healthcheck.sh
  mods/eap
  sites/site
  sites/proxy-inner-tunnel
docs/
  authentik.md      provider, outpost, flow and token setup
  unifi.md          controller RADIUS profile and SSID setup
  clients.md        Windows / Android / iOS / Linux supplicant configuration
  troubleshooting.md
README.md
```

Deleted: `environment/`, `img/`, `wpa2_supplicant.conf` (its content moves into
`docs/clients.md` as a Linux example, with the lab credentials replaced by placeholders),
`freeradius/clients.conf.template`.

`.gitignore` stops ignoring `docker-compose.yml`; starts ignoring `.env` and
`docker-compose.override.yml`.

### 5.2 Dockerfile

- `FROM freeradius/freeradius-server:3.2.10-alpine`
- `RUN openssl genpkey -genparam -algorithm DH -pkeyopt group:ffdhe2048 -out /etc/raddb/certs/dh.pem`
  — RFC 7919 named group; deterministic output, no prime search. Requires OpenSSL 3.x,
  which Alpine provides.
- Copy configuration; enable only the `site` and `proxy-inner-tunnel` virtual servers.
- OCI labels (`org.opencontainers.image.source`, `.description`, `.licenses`, `.revision`).
- `EXPOSE 1812/udp`.
- `HEALTHCHECK` invoking `freeradius/healthcheck.sh` (section 5.5).
- Built for `linux/amd64` and `linux/arm64`.

### 5.3 FreeRADIUS configuration

**`clients.conf`** — static file, no templating:

```
client uplink {
    ipaddr  = $ENV{RADIUS_CLIENT_NET}
    secret  = $ENV{RADIUS_SECRET}
    require_message_authenticator = yes
}

client healthcheck {
    ipaddr  = 127.0.0.1
    secret  = $ENV{RADIUS_HEALTHCHECK_SECRET}
    require_message_authenticator = no
}

home_server authentik {
    type           = auth
    ipaddr         = authentik_radius
    port           = 1812
    secret         = $ENV{AUTHENTIK_RADIUS_SECRET}
    status_check   = status-server
    check_interval = 30
    num_answers_to_alive = 3
    response_window = 10
    revive_interval = 60
}

home_server_pool authentik { type = fail-over  home_server = authentik }

realm authentik { auth_pool = authentik  nostrip }
```

`require_message_authenticator = yes` is retained on the uplink client: UniFi includes
Message-Authenticator in EAP Access-Requests (RFC 3579 requires it), and it mitigates
BlastRADIUS (CVE-2024-3596). The healthcheck client is 127.0.0.1-only inside the
container's own network namespace.

The realm name stays the literal `authentik`, because `sites/proxy-inner-tunnel` refers to
it by name (`Proxy-To-Realm := "authentik"`). Making it configurable would require
templating both files for no operational benefit. For the same reason the home server's
`ipaddr` is the literal Compose service name `authentik_radius`, resolved by the Docker
network's DNS at startup, rather than a variable: the two services are defined in the same
`docker-compose.yml`, so the name cannot drift independently.

Whether `$ENV{}` expands correctly in every position used here — in particular `ipaddr` in
a `client` block — is not assumed: the CI `radiusd -XC` job (section 5.8) parses this file
on every push and fails the build if it does not.

**`mods/eap`** — `staple`/`ocsp` disabled, `check_crl`/`check_all_crl` removed, TLS pinned
to 1.2–1.3, `auto_chain = yes` retained so the mounted `fullchain.pem` supplies the
intermediate. `use_tunneled_reply = yes` and `copy_request_to_tunnel = yes` are retained —
`use_tunneled_reply` is the mechanism that will carry `Tunnel-Private-Group-Id` out to the
AP when dynamic VLAN is implemented (section 7).

**`radiusd.conf`** — add `proxy_requests = yes`. `security { status_server = yes }` is
already present and is what makes the healthcheck's Status-Server probe answerable.

**`sites/site`, `sites/proxy-inner-tunnel`** — unchanged. They are correct.

### 5.4 `entrypoint.sh`

1. `set -eu`.
2. Require `RADIUS_SECRET`, `AUTHENTIK_RADIUS_SECRET`, `RADIUS_CLIENT_NET`; exit non-zero
   with a named-variable error message if any is unset or empty.
3. Verify `/etc/raddb/certs/server.crt` and `server.key` exist and are readable; exit with
   a specific message if not. (Today a missing mount produces an opaque TLS error.)
4. Generate a random `RADIUS_HEALTHCHECK_SECRET`, export it, and write it to
   `/run/radiusd/healthcheck.secret` mode 0600 for `healthcheck.sh` to read. No default
   secret exists anywhere in the repository.
5. If `CERT_RELOAD_WATCH=true`, start a background loop polling the certificate's mtime
   every `CERT_RELOAD_INTERVAL` seconds (default 3600); on change, signal the radiusd PID
   to terminate. The container's `restart: unless-stopped` policy restarts it with the
   renewed certificate. Downtime is roughly the container start time, a few seconds, once
   per renewal.
6. `exec` radiusd, with `-X` when `FREERADIUS_ENABLE_DEBUG=true`, passing through `"$@"`.

The debug flag is documented as **development only**: `-X` logs the inner-tunnel exchange,
which includes the user's cleartext password.

### 5.5 `healthcheck.sh`

Sends a RADIUS Status-Server packet to `127.0.0.1:1812` via `radclient`, using the secret
from `/run/radiusd/healthcheck.secret`. Exit 0 on a response. This proves the daemon is
listening and processing packets, not merely that the process exists. It deliberately does
not probe authentik — the home-server `status_check` handles that, and a failing IdP
should not cause the RADIUS container to be restarted.

### 5.6 `docker-compose.yml`

Committed, image-based, no `build:` — Portainer's git-backed stack pulls and runs it.

- `authentik_radius`: `ghcr.io/goauthentik/radius:${AUTHENTIK_VERSION}`, healthcheck on
  the existing `/outpost.goauthentik.io/ping` endpoint.
- `freeradius`: `ghcr.io/wus-technik/authentik-freeradius:${IMAGE_TAG:-latest}`,
  `depends_on: authentik_radius: condition: service_healthy`, ports
  `${RADIUS_LISTEN_ADDR:-0.0.0.0}:1812:1812/udp`, certificate paths bind-mounted read-only
  from host variables, `cap_drop: [ALL]`, `read_only: true` with tmpfs for `/run/radiusd`
  and `/tmp/radiusd`, `restart: unless-stopped`, and json-file log rotation.

No `version:` key — it is obsolete in Compose v2 and emits a warning.

`docker-compose.override.yml.example` restores a `build: .` context for local development.

**Portainer note:** variables are supplied through Portainer's stack environment-variable
UI, not a repository `.env` file. `.env.example` documents the full set and doubles as the
list to paste in. The GHCR package is **public**, so Portainer needs no registry
credentials.

### 5.7 `.env.example`

| Variable | Required | Purpose |
|---|---|---|
| `IMAGE_TAG` | no | FreeRADIUS image tag, default `latest` |
| `AUTHENTIK_VERSION` | yes | authentik outpost image tag; must match the authentik server version |
| `AUTHENTIK_HOST` | yes | authentik base URL |
| `AUTHENTIK_TOKEN` | yes | outpost token from authentik |
| `AUTHENTIK_RADIUS_SECRET` | yes | shared secret between FreeRADIUS and the outpost; must equal the RADIUS provider's secret in authentik |
| `RADIUS_SECRET` | yes | shared secret between the UniFi APs and FreeRADIUS |
| `RADIUS_CLIENT_NET` | yes | CIDR of the APs / controller permitted to send requests |
| `RADIUS_LISTEN_ADDR` | no | bind address, default `0.0.0.0` |
| `TLS_CERT_PATH` | yes | host path to `fullchain.pem` |
| `TLS_KEY_PATH` | yes | host path to `privkey.pem` |
| `CERT_RELOAD_WATCH` | no | restart on certificate change, default `false` |
| `CERT_RELOAD_INTERVAL` | no | poll seconds, default `3600` |
| `FREERADIUS_ENABLE_DEBUG` | no | `-X` debug logging, default `false`; **logs cleartext passwords** |

### 5.8 GitHub Actions — `.github/workflows/build.yml`

Triggers: push to `develop` and `main`, tags `v*`, pull requests targeting either branch,
weekly schedule (base-image CVE refresh), and `workflow_dispatch`.

Permissions: `contents: read`, `packages: write`, `attestations: write`, `id-token: write`.
Concurrency group per ref, cancelling in-progress runs.

**Job `lint`** — `hadolint` on the Dockerfile, `shellcheck` on `entrypoint.sh` and
`healthcheck.sh`.

**Job `validate`** — builds `linux/amd64` with `load: true`, generates a throwaway
self-signed certificate, and runs `radiusd -XC` inside the image with dummy secrets. This
is a genuine configuration-syntax gate: a typo in `mods/eap` or `clients.conf` fails the
build rather than the WiFi.

**Job `build`** — needs `lint` and `validate`. QEMU + Buildx, multi-arch `linux/amd64` and
`linux/arm64`, login to GHCR, `docker/metadata-action` tagging (branch name, semver from
`v*` tags, short SHA, `latest` only on `main`), GitHub Actions build cache, provenance and
SBOM attestations. `push` is false on pull requests.

Action versions, each verified to declare `using: node24`:
`actions/checkout@v7`, `docker/setup-qemu-action@v4`, `docker/setup-buildx-action@v4`,
`docker/login-action@v4`, `docker/metadata-action@v6`, `docker/build-push-action@v7`.

### 5.9 Documentation

`README.md` is rewritten to state what the project is, why the FreeRADIUS detour is
necessary (with the #5328 citations from section 1), the request-flow diagram, a quickstart
for the Portainer stack, and the security notes. The `docs/` files cover authentik-side
setup, UniFi-side setup, client supplicant configuration, and troubleshooting with
`eapol_test`, which — unlike `radtest` — exercises the real EAP-TTLS path.

`docs/clients.md` must state plainly that a public Let's Encrypt certificate does not
remove client provisioning: Android 11+ and Windows still require the CA and the server
domain to be pinned in a profile, or users are prompted and may accept an impostor. This is
an Intune/GPO task the stack cannot solve.

## 6. Testing

The stack has no unit-testable code; verification is layered:

1. **CI, every push.** `hadolint`, `shellcheck`, and `radiusd -XC` against the built image
   — configuration syntax and shell correctness.
2. **Local, manual.** `docker compose up` with a self-signed certificate, then
   `eapol_test -c <ttls.conf> -a 127.0.0.1 -p 1812 -s <secret>` for a full EAP-TTLS
   exchange, and `radtest` PAP directly against the outpost to isolate which half fails.
3. **Deployment, manual.** One real client per platform (Windows, Android, iOS, Linux) on
   the live SSID.

Levels 2 and 3 require a running Docker daemon and a live authentik instance; they are
documented in `docs/troubleshooting.md` as a checklist rather than automated.

## 7. Deferred work (GitHub issues)

Two issues to be opened in `wus-technik/authentik-freeradius`:

**RADIUS accounting (UDP 1813).** UniFi sends Accounting-Request start/stop/interim records
when accounting is enabled on the RADIUS profile. FreeRADIUS currently has no `type = acct`
listener and 1813 is not published, so those requests time out. Needs an accounting
listener, an `accounting` section in `sites/site`, a port publication, and a decision on
whether records are proxied to authentik, written locally, or discarded.

**Dynamic VLAN assignment per user/group.** Place users into VLANs by authentik group
membership. authentik returns `Tunnel-Type`, `Tunnel-Medium-Type` and
`Tunnel-Private-Group-Id` from RADIUS property mappings; `use_tunneled_reply = yes` (already
set) copies them from the inner tunnel to the outer Access-Accept the AP acts on. Requested
repeatedly in #5328 (koalaeagle 2023-05-20, KautzA 2023-05-24, cheggerdev 2025-04-23).
cheggerdev notes that authentik bugs #16980 and #16993 obstruct this — both must be checked
before implementation.

## 8. Open items

- **Licence.** The repository has no `LICENSE`. Its ancestor `tknv/docker-radius-eap-ttls`
  no longer exists on GitHub, so its licence terms cannot be established. Adding a licence
  is Christian's decision, not one to make silently; no `LICENSE` file is added by this
  work.
