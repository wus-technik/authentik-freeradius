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

Optionally, with [`docker-compose.peap.yml`](docker-compose.peap.yml), FreeRADIUS also
speaks **PEAP-MSCHAPv2**: no client profile on any platform, with a separate WiFi password
that users generate in authentik and that FreeRADIUS checks via the authentik LDAP
outpost. See [docs/authentik.md § 6](docs/authentik.md#6-wifi-password-for-peap-optional).

## Security properties — read before deploying

This design is a workaround, and it has a real cost:

- **FreeRADIUS sees every user's cleartext password.** EAP-TTLS/PAP means the inner
  exchange is a plaintext password, decrypted by this container.
- **It is forwarded to the outpost as PAP.** RADIUS shared-secret obfuscation is not
  transport security.

Therefore: keep both containers on a private Docker network on a trusted host, never
publish the outpost's RADIUS port, and use long random shared secrets
(`openssl rand -hex 32`). Anyone who compromises this host can read staff passwords.
- **Shared secrets are visible via container inspection.** They are passed as compose
  environment variables, so anyone with Docker socket or Portainer access can read them
  with `docker inspect` or Portainer's stack view.
- **With PEAP, authentik stores an NT hash per user** (`wifi-password-nthash`). It is
  equivalent to that user's WiFi password — not to their SSO password. The LDAP service
  account can read all of them, and so can any account with "Search full LDAP directory"
  on any other LDAP provider in the same authentik; audit those before rollout.

`FREERADIUS_ENABLE_DEBUG=true` logs the inner tunnel, cleartext passwords included. It is
for development only.

## Quickstart (Portainer git-backed stack)

1. Point a Portainer stack at this repository, `docker-compose.yml`.
2. Fill in the stack environment variables from [`.env.example`](.env.example).
3. Make sure the host has a certificate for the RADIUS server name and that
   `LETSENCRYPT_DIR` is readable by Docker.
4. Leave `RADIUS_NET_SUBNET` at its default unless it collides with a network on the
   host. Both outposts get fixed addresses inside it; nothing depends on DNS. To check,
   list the subnets of all networks on the host and look for any that contains
   `RADIUS_NET_SUBNET`, including larger ones such as a `/16` — the network names alone
   do not show it:

   ```bash
   docker network inspect $(docker network ls -q) \
     --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'
   ```
5. Deploy, then follow [docs/authentik.md](docs/authentik.md) and
   [docs/unifi.md](docs/unifi.md).

Certificate renewals need `CERT_RELOAD_WATCH=true`: FreeRADIUS reads TLS material once at
startup, so without it the container serves the old certificate until someone restarts it.
[docs/certificates.md](docs/certificates.md) has a worked rollout that keeps renewals
hands-off.

### Deploy the stack twice

`freeradius` waits for the outpost via `depends_on: condition: service_healthy`, and the
outpost needs **roughly 25 seconds** to become healthy — it first waits for the authentik
server, logging `503 ... retrying` while it does. Portainer returns before that, and
**`freeradius` is left sitting in `created` and never starts.**

Redeploy the identical stack a second time and it comes up. Starting the container through
the Docker API (Portainer's `POST /containers/<id>/start`) does **not** work.

A container list taken immediately after a deploy shows everything as `created`. That is
the start in progress, not a failure — look again once the outpost reports healthy.

## Documentation

- [docs/authentik.md](docs/authentik.md) — provider, outpost and token
- [docs/unifi.md](docs/unifi.md) — RADIUS profile and SSID
- [docs/clients.md](docs/clients.md) — Windows, Android, iOS, macOS, Linux, and PEAP without a profile
- [docs/troubleshooting.md](docs/troubleshooting.md) — when it does not work
- [docs/certificates.md](docs/certificates.md) — issuing and rotating the server certificate
- [docs/migration.md](docs/migration.md) — replacing an existing PEAP/MSCHAPv2 RADIUS
- [docs/monitoring.md](docs/monitoring.md) — Zabbix integration
- [docs/rollout-mail.de.md](docs/rollout-mail.de.md) — template mail to users (German)

## Development

```bash
cp docker-compose.override.yml.example docker-compose.override.yml   # build from source
./test/e2e/run.sh                                                    # end-to-end suite
```

`test/e2e/run.sh` drives a real EAP-TTLS exchange with `eapol_test` against a stand-in
outpost, including an outage/recovery cycle. Run it before every push — a `radiusd -XC`
syntax check alone does **not** catch the failure modes that matter here.

## Not implemented

- RADIUS accounting (UDP 1813) — #1
