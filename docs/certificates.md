# The server certificate

FreeRADIUS presents this certificate to every supplicant. Two properties matter, and they
pull in opposite directions:

- **Clients must trust the issuer and recognise the name.** A publicly-trusted certificate
  removes the need to distribute a private CA, but see
  [docs/clients.md](clients.md) — trusting the issuer is not enough on its own, every
  managed device must also be pinned to the expected CA *and* server name.
- **It expires.** A 90-day certificate renewed every 60 days means six unattended
  swaps a year. Anything that needs a human at renewal time will eventually be missed, and
  the failure is silent until a client refuses to connect.

## What the container expects

`TLS_CERT_PATH` and `TLS_KEY_PATH` are **container** paths under `/etc/letsencrypt`, which
is the host directory `LETSENCRYPT_DIR` mounted read-only. Mount the **whole tree**, never
individual `.pem` files: ACME clients repoint the `live/` symlinks at new `archive/` files,
and a file mount pins the old inode so the container serves a stale certificate forever.

`CERT_RELOAD_WATCH=true` polls the certificate every `CERT_RELOAD_INTERVAL` seconds and
restarts the container when it changes. Without it, FreeRADIUS keeps serving whatever it
read at startup.

## Reference rollout: ACME on an edge device

This is a deployment that has been shown to work end to end and needs no intervention
between renewals. It suits sites where the RADIUS host has no inbound HTTP exposure.

1. **Issue on the edge device.** An ACME client on the firewall/router holds the account
   and issues the certificate for the RADIUS server name using a **DNS-01** challenge — so
   the RADIUS host itself never needs to be reachable from the internet. 4096-bit key,
   auto-renewal every 60 days.
2. **Push to the Docker host.** The ACME client's post-issuance *action* copies
   `fullchain.pem` and `privkey.pem` over SFTP into the host directory that
   `LETSENCRYPT_DIR` maps, laid out the way the container expects:

   ```
   <LETSENCRYPT_DIR>/live/<radius server name>/fullchain.pem
   <LETSENCRYPT_DIR>/live/<radius server name>/privkey.pem
   ```

   The action needs an SSH identity on the ACME client and the matching public key on the
   Docker host. Restrict that key to the upload — it writes material FreeRADIUS trusts.
3. **Let the container notice.** `CERT_RELOAD_WATCH=true` picks the new file up within
   `CERT_RELOAD_INTERVAL` and restarts FreeRADIUS — a few seconds of authentication
   downtime per renewal.

**The critical detail:** the action must run on **renewal**, not only on first issuance.
On OPNsense's ACME client, and on most implementations, configured actions run after every
successful issuance *and* every renewal — so steps 2 and 3 together cover the 60-day
rotation with nobody in the loop. Verify this on your own ACME client before relying on
it; an action that fires only once turns into an outage 60 days later.

## Verify it worked

```bash
#  what the container will read
docker compose exec freeradius openssl x509 -noout -subject -enddate \
  -in "$TLS_CERT_PATH"

#  what it is actually serving
openssl s_client -connect <radius host>:1812 2>/dev/null </dev/null
```

`s_client` does not speak RADIUS/EAP, so for the served certificate use the e2e rig
(`./test/e2e/run.sh`) or an `eapol_test` run against the live server instead.

## If you are replacing an existing RADIUS

Swapping to a new certificate changes the issuer and usually the CN, which breaks every
client that validates either. Read [docs/migration.md](migration.md) before you plan the
cutover.
