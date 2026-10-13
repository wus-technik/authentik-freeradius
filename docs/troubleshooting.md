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

**`Ignoring request ... from unknown client`** — the AP's address is outside
`RADIUS_CLIENT_NET`.

**`Received packet ... with invalid Message-Authenticator! (Shared secret is incorrect.)`**
— `RADIUS_SECRET` does not match the UniFi RADIUS profile.

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

**Authentication stopped after the outpost alone was recreated** — an authentik version
bump, an image update, or `docker compose up -d authentik_radius` replaces that container
and Docker gives it a new bridge address. FreeRADIUS resolves the outpost **once at
startup**, so the container checks the name every `OUTPOST_RESOLVE_INTERVAL` seconds
(default 15) and restarts itself when the address has moved. Expect a short gap, then:

```bash
docker compose logs freeradius | grep 'outpost address changed'
```

If authentication stays down, check that the watcher is running at all: it logs
`address watcher armed` at startup, it is off when `OUTPOST_RESOLVE_INTERVAL=0` or when
`AUTHENTIK_RADIUS_HOST` is a literal address, and it depends on the `restart:` policy to
bring the container back.

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
