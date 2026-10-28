# Troubleshooting

Work from the outside in: supplicant → AP → FreeRADIUS → outpost → authentik.

## Which log is the witness

Before reading any log, know what it can and cannot prove.

**FreeRADIUS logs nothing in normal operation.** `log { auth }` is off, so a successful
— or even an attempted — authentication leaves no trace. **An empty FreeRADIUS log is not
evidence that no request arrived.** Only errors and startup messages appear there.

**The outpost log is the witness.** Every request FreeRADIUS proxies inward shows up as a
`Radius Request` line. That splits the chain in two:

| Outpost log | Where the fault is |
|---|---|
| no `Radius Request` | the **outer** leg — supplicant, AP, or the EAP-TTLS tunnel to FreeRADIUS |
| `Radius Request` present, then a reject or flow error | the **inner** leg — outpost, provider binding, authentik flow, or the user's credentials |

```bash
docker compose logs -f authentik_radius | grep -i 'radius request'
```

**Do not use the controller's event log as a witness.** On UniFi the `stat/event`
endpoint can return an empty list permanently for a site, regardless of what the APs are
doing. Its silence means nothing.

If you need FreeRADIUS itself to speak up, turn on debug logging (see below) — but note
that it prints cleartext passwords, so it is a deliberate, temporary step, not a default.

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
   /opt/bin/radclient authentik_radius:1812 auth "$AUTHENTIK_RADIUS_SECRET"'
```

Use a disposable test account here, not a real user's credentials - `radclient` output and shell history are not a safe place for a live password.

`radclient` is **not on `PATH`** in this image — it lives at `/opt/bin/radclient`, and a
bare `radclient` call fails with `not found`.

Access-Accept means authentik and the outpost are fine and the problem is in the EAP half.

## Symptoms

**`Ignoring request ... from unknown client`** — the AP's address is outside every network
in `RADIUS_CLIENT_NET`. The APs send from their own management address, not from the
controller; behind NAT, FreeRADIUS sees the translated one.

**`Received packet ... with invalid Message-Authenticator! (Shared secret is incorrect.)`**
— the secret in the UniFi RADIUS profile does not match the one FreeRADIUS uses for that
AP's network: the secret of its site in `RADIUS_SITE_SECRETS`, or `RADIUS_SECRET` for a
network without a site. The startup log names which one each network uses
(`entrypoint: RADIUS client <net>, secret of site <site>`).

**`No provider found` with `hashed_secret` in the outpost log** — `AUTHENTIK_RADIUS_SECRET`
does not match the shared secret on authentik's RADIUS provider.

**The `freeradius` container sits in `created` and never starts, right after a deploy** —
see the deploy note in the [README](../README.md#quickstart-portainer-git-backed-stack).
`depends_on: condition: service_healthy` outruns the orchestrator: redeploy the identical
stack a second time. Starting the container through the Docker API alone does not work.

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

**`AUTHENTIK_RADIUS_HOST must be a literal IPv4 address`** — the outpost is addressed by
its fixed IP on the `radius` network, never by name. A stopped container's name is
forwarded to the host's resolver, which can answer with an address outside the stack;
FreeRADIUS would then send inner requests there (issue #15). Keep
`AUTHENTIK_RADIUS_HOST: ${AUTHENTIK_RADIUS_IP}` from `docker-compose.yml`.

**Upgrading from a version without fixed addresses** — the `radius` network gets a fixed
subnet. A current Docker Compose recreates the network and the containers on the next
deploy by itself. If the deploy fails on the network instead, or the outpost does not come
up on `AUTHENTIK_RADIUS_IP`, remove the old network once and deploy again:

```bash
docker compose down
docker network rm <stack>_radius
```

In Portainer: stop the stack, delete the `<stack>_radius` network under **Networks**,
then deploy. Check the result with `docker network inspect <stack>_radius`.

After the upgrade FreeRADIUS sends from an address on the new `radius` network. Set
**Client Networks** of the RADIUS provider in authentik to `RADIUS_NET_SUBNET` — otherwise
the outpost silently drops every inner request and EAP-TTLS stops working, see the next
entry.

**Inner requests time out, nothing in the outpost log** — the outpost drops requests from
addresses outside the provider's **Client Networks** without answering and without logging
anything. `radclient` (see [Test only the outpost half](#test-only-the-outpost-half))
shows `No reply from server`. Set Client Networks to `RADIUS_NET_SUBNET`. FreeRADIUS has no
fixed address of its own, so the subnet is the value that survives a container recreate.

**Authentication stopped working weeks after deployment** — the certificate was renewed and
the container is still serving the old one. Set `CERT_RELOAD_WATCH=true`, and confirm
`LETSENCRYPT_DIR` mounts the whole tree rather than individual `.pem` files: certbot
repoints the `live/` symlinks, so a file mount pins the old inode.

**Refused, `ttls: inner EAP instead of PAP, the device needs a TTLS profile or PEAP:
<user>`** — the device took EAP-TTLS without a profile that sets PAP inside the tunnel;
iOS and macOS do that when they join an SSID by hand. With `PEAP_ENABLE=true` such devices
are offered PEAP first and do not get here. Without PEAP, they need a `.mobileconfig`
with `TTLSInnerAuthentication` = `PAP` ([clients.md](clients.md)).

**PEAP login refused, `peap: no active WLAN user with a WiFi password: <user>`** — the
directory had no match: the user is deactivated, not in the WLAN group, has no WiFi
password yet, or typed a different username. EAP-TTLS is unaffected. A name with a
domain (`jdoe@example.com`, `EXAMPLE\jdoe`) is found only with `USERNAME_STRIP_DOMAIN` or
`USERNAME_STRIP_NTDOMAIN` switched on; the log line shows the name as the client sent it.

**PEAP login refused, `peap: wrong WiFi password: <user>`** — the user was found, but the
password does not match the stored WiFi password: a typo, the SSO password instead of the
WiFi password, or a device still using a password that has since been replaced.

**PEAP refused, `rlm_ldap … failed: Can't contact LDAP server`** — the LDAP outpost is
down or not at `AUTHENTIK_LDAP_IP`. PEAP fails within seconds; EAP-TTLS keeps working. The
connection pool reconnects by itself once the outpost is back.

**PEAP refused, `rlm_ldap … failed: Invalid credentials`** — `LDAP_BIND_PASSWORD` is not a
valid token of `svc-wlan-ldap`, or the token expired.

**`<VAR> may only contain A-Z a-z 0-9 = , . _ - and spaces`** — one of `LDAP_BASE_DN`,
`LDAP_BIND_DN`, `LDAP_WLAN_GROUP_DN` has a character outside that set (`+`, `#`,
parentheses, non-ASCII) or is longer than 255 characters. Rename the group or user so its
DN avoids them.

**`<VAR> must be a single line`** — the same variables contain a line break, usually from a
pasted value in the stack environment. Put the DN on one line.

## Debug logging

```bash
FREERADIUS_ENABLE_DEBUG=true docker compose up freeradius
```

**This logs cleartext passwords.** Development only; never leave it on.

## Client compatibility

The server caps TLS at 1.2 deliberately — FreeRADIUS 3.2 advises against TLS 1.3 for EAP
because supplicant support is uneven. If you raise `tls_max_version` to `"1.3"`, retest
Windows, Android, iOS and Linux before rolling out.
