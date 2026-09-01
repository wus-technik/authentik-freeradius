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
   /opt/bin/radclient authentik_radius:1812 auth "$AUTHENTIK_RADIUS_SECRET"'
```

Use a disposable test account here, not a real user's credentials - `radclient` output and shell history are not a safe place for a live password.

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
