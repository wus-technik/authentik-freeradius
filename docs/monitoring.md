# Monitoring with Zabbix

Written for **Zabbix 7.4 with agent 2** on the Docker host. Every command and item key
below was run against a live container from `test/e2e`, except where marked *unverified*.

This stack exposes four independent signals, and they fail in different ways. A healthy
container proves nothing about whether authentication works.

| Layer | Source | Catches |
|---|---|---|
| 1. Container health | Docker API, agent 2 | crash loops, `entrypoint:` validation failures, outpost unable to reach authentik |
| 2. RADIUS statistics | `radclient` against the status listener | radiusd not answering; auth/reject/proxy counters; dead air |
| 3. Outpost metrics | Prometheus endpoint on `:9300` | outpost → authentik HTTP problems |
| 4. Container logs | json-file or syslog | dead home server, unknown client, wrong shared secret |

Plus certificate expiry, the most likely cause of a silent outage weeks after a working
deployment.

## 1. Container health

Attach the stock **Docker by Zabbix agent 2** template to the Docker host. Give the agent
the socket first:

```ini
# /etc/zabbix/zabbix_agent2.d/plugins.d/docker.conf
Plugins.Docker.Endpoint=unix:///var/run/docker.sock
Plugins.Docker.Timeout=10
```

```bash
usermod -aG docker zabbix && systemctl restart zabbix-agent2
```

Membership in `docker` is root-equivalent on that host. If that is unacceptable, put
`tecnativa/docker-socket-proxy` (with `CONTAINERS=1` and nothing else) in front and point
`Plugins.Docker.Endpoint` at it.

The template discovers containers via `docker.containers.discovery[false]` and already
ships what this stack needs — **no custom trigger required**:

- `docker.container_info.state.health["{#NAME}"]` with the trigger
  *Health state container is unhealthy* (HIGH, fires on two consecutive unhealthy values
  within 2m). Both images ship a real healthcheck — `freeradius` sends itself a
  Status-Server packet, the outpost image verifies its own connection to authentik — so
  this is a meaningful signal, not a liveness placebo.
- `docker.container_info.restart_count["{#NAME}"]` — worth your own trigger, since a crash
  loop from a bad `RADIUS_SECRET` or a missing certificate mount restarts faster than the
  health poll notices:

  ```
  change(/Docker by Zabbix agent 2/docker.container_info.restart_count["freeradius"])>0
  ```

Note the discovery argument: `false` means **running containers only**. A container that
is gone stops being discovered rather than turning red, so back it up with a `nodata()`
trigger or watch the host-level `docker.containers.stopped`.

## 2. RADIUS statistics

### Why this needed a change to the image

A `type = auth` listener answers Status-Server with a bare Access-Accept — that is what the
container healthcheck relies on. FreeRADIUS returns the internal counters **only** from a
`type = status` listener. Sending `FreeRADIUS-Statistics-Type` to port 1812 is accepted and
silently ignored.

So the image now enables a second, loopback-only listener,
[`freeradius/sites/status`](../freeradius/sites/status) on `127.0.0.1:18121`, using the
same per-start random secret that `entrypoint.sh` already generates for the healthcheck.
Nothing new is exposed and no secret has to be configured on the monitoring side — reading
the counters requires `docker exec`, which already implies root on the host.

That change is not free of side effects, and the reason is documented in
[`freeradius/sites/site`](../freeradius/sites/site): as soon as *any* virtual server
defines an `Autz-Type Status-Server` section, the core stops replying Access-Accept to
Status-Server by default and runs the default server's `authorize` instead — which fell
through to Access-Reject and left the container permanently unhealthy. The default site now
answers `Autz-Type Status-Server` explicitly. `test/e2e/run.sh` passes with both changes in
place; keep it that way if you touch either file.

### Reading the counters

```bash
docker exec freeradius sh -c \
  'printf "Message-Authenticator = 0x00\nFreeRADIUS-Statistics-Type = All\n" | \
   /opt/bin/radclient -x -t 2 -r 1 127.0.0.1:18121 status "$(cat /run/radiusd/healthcheck.secret)"'
```

Substitute the real container name (`docker ps --format '{{.Names}}'`); under a Portainer
stack it is usually `<stack>_freeradius_1` or `<stack>-freeradius-1`.

### One collector, many items

Do not run one `radclient` call per metric. [`contrib/zabbix/zbx_radius_stats.sh`](../contrib/zabbix/zbx_radius_stats.sh)
collects once and emits a flat JSON object:

```bash
install -m 0755 contrib/zabbix/zbx_radius_stats.sh /usr/local/bin/
```

```ini
# /etc/zabbix/zabbix_agent2.d/radius.conf
UserParameter=freeradius.stats[*],/usr/local/bin/zbx_radius_stats.sh "$1"
```

It keeps only the `FreeRADIUS-Total-*` attributes: the `FreeRADIUS-Stats-Elapsed-*` buckets
repeat once per section in the reply and would collide as JSON keys. When radiusd does not
answer it prints `{}` and exits 0, so the item stays supported and the outage shows up as
a value, not as a red item nobody looks at.

### Import the template

[`contrib/zabbix/template_authentik_freeradius.yaml`](../contrib/zabbix/template_authentik_freeradius.yaml)
contains everything in this section plus the certificate check from section 5: 12 items,
8 triggers with dependencies, a dashboard and six macros. It was import-tested against
Zabbix 7.4.14 (*Data collection → Templates → Import*).

Set at least `{$FREERADIUS.CONTAINER}` and `{$FREERADIUS.CERT.PATH}` on the host after
linking. The other macros — `{$FREERADIUS.DEADAIR.PERIOD}` (1h),
`{$FREERADIUS.REJECT.MIN.RATE}` (0.01), `{$FREERADIUS.CERT.WARN.DAYS}` (14),
`{$FREERADIUS.CERT.CRIT.DAYS}` (3) — have working defaults.

The template deliberately does **not** cover container health; that is layer 1's stock
template, which already does it better.

If you would rather build the items by hand, the rest of this section is what the template
contains.

Master item `freeradius.stats[freeradius]`, type *Zabbix agent*, type of information
*Text*, interval 1m. Dependent items, all with **JSONPath** plus **Change per second**:

| Suggested key | JSONPath |
|---|---|
| `radius.requests` | `$['FreeRADIUS-Total-Access-Requests']` |
| `radius.accepts` | `$['FreeRADIUS-Total-Access-Accepts']` |
| `radius.rejects` | `$['FreeRADIUS-Total-Access-Rejects']` |
| `radius.challenges` | `$['FreeRADIUS-Total-Access-Challenges']` |
| `radius.dropped` | `$['FreeRADIUS-Total-Auth-Dropped-Requests']` |
| `radius.malformed` | `$['FreeRADIUS-Total-Auth-Malformed-Requests']` |
| `radius.invalid` | `$['FreeRADIUS-Total-Auth-Invalid-Requests']` |
| `radius.proxy_requests` | `$['FreeRADIUS-Total-Proxy-Access-Requests']` |
| `radius.proxy_accepts` | `$['FreeRADIUS-Total-Proxy-Access-Accepts']` |
| `radius.proxy_dropped` | `$['FreeRADIUS-Total-Proxy-Auth-Dropped-Requests']` |

Expect `Access-Challenges` to be several times `Access-Requests`: one EAP-TTLS
authentication is a whole round-trip sequence. A single successful login through the e2e
harness produced 6 requests, 4 challenges, 1 accept, 1 proxy request, 1 proxy accept.

The accounting counters (`FreeRADIUS-Total-Accounting-*`) are present in the reply and will
stay at zero — accounting is not implemented (#1).

### Triggers that matter

```
# radiusd is not answering at all
length(last(/RADIUS/freeradius.stats[freeradius]))<5

# dead air: the APs never go quiet during the working day
avg(/RADIUS/radius.requests,1h)=0

# reject storm, with real traffic present
avg(/RADIUS/radius.rejects,15m)>avg(/RADIUS/radius.accepts,15m)
  and avg(/RADIUS/radius.requests,15m)>0.01

# the outpost leg is not answering: we proxy, nothing comes back
avg(/RADIUS/radius.proxy_requests,10m)>0 and avg(/RADIUS/radius.proxy_accepts,10m)=0
```

**Dead air is the one to get right.** Every silent outage this design is prone to — a
renewed certificate the container never picked up, a home server marked dead, an AP profile
edited in UniFi — presents as *no traffic*, not as errors. Severity High, with a time
period condition if the site is genuinely idle at night.

The last trigger is the substitute for a per-home-server state metric.
`FreeRADIUS-Statistics-Type = Home-Server` with `FreeRADIUS-Stats-Server-IP-Address` was
tried and returns nothing useful for this configuration, so the outpost's state is inferred
from the proxy counters and from the log trigger in section 4 instead.

### If the agent must not have Docker access

Then poll 1812 from the monitoring host, which needs its own client block — the AP secret
must not be reused:

```
client monitoring {
	ipaddr = $ENV{RADIUS_MONITOR_NET}
	secret = "$ENV{RADIUS_MONITOR_SECRET}"
	require_message_authenticator = yes
}
```

plus both variables in `docker-compose.yml` and `.env.example`, and `freeradius-utils` on
the monitoring host. This buys liveness only: the statistics listener is bound to
`127.0.0.1` and is not reachable this way. Widening it to the monitoring network would put
an unauthenticated-by-design counter interface on the wire. **The repository does not ship
this block** — it is a change you would have to make.

## 3. authentik outpost metrics

*Unverified locally — the outpost only opens this port once it can reach authentik.*

The outpost already serves Prometheus metrics: `AUTHENTIK_LISTEN__METRICS: 0.0.0.0:9300`
is set in `docker-compose.yml`. The port is not published, so bind it to loopback:

```yaml
  authentik_radius:
    ports:
      - "127.0.0.1:9300:9300"
```

Loopback only — the endpoint is unauthenticated.

Then one **HTTP agent** master item on `http://127.0.0.1:9300/metrics`, interval 1m, with
dependent items using **Prometheus pattern** preprocessing. Read the endpoint once with
`curl -s 127.0.0.1:9300/metrics` and pick names from what it actually emits; they change
between authentik versions. Besides the outpost's own request counters, `go_goroutines` and
`process_resident_memory_bytes` make useful leak canaries.

What this does *not* tell you: the outpost only sees requests that already made it through
the EAP-TTLS tunnel. Layer 2 sits upstream and sees strictly more.

## 4. Log triggers

`docker-compose.yml` uses the `json-file` driver, whose path contains the container ID and
therefore changes on every recreate. Two workable options:

**a) Switch both services to syslog** and read the host file with a Zabbix `log[]` item:

```yaml
    logging:
      driver: syslog
      options:
        tag: "{{.Name}}"
```

**b) Keep json-file** and let the agent resolve the path each poll:

```ini
UserParameter=docker.logfile[*],docker inspect --format '{{.LogPath}}' "$1"
```

The patterns worth alerting on come straight from [troubleshooting.md](troubleshooting.md):

| Pattern | Meaning | Severity |
|---|---|---|
| `Marking home server .* as dead` with no later `alive` | outpost down; with `status_check = none` it cannot self-revive | Disaster |
| `invalid Message-Authenticator` | `RADIUS_SECRET` mismatch, or an unconfigured AP | High |
| `Ignoring request .* from unknown client` | AP outside `RADIUS_CLIENT_NET` | Warning |
| `entrypoint: ` | startup validation failed; the container is about to exit | High |
| `certificate changed, restarting radiusd` | informational — confirms the renewal watcher fired | Information |

The first deserves the highest severity in the set: it is unrecoverable without a restart.

## 5. Certificate expiry

The EAP server certificate cannot be probed over the network — it lives inside the
EAP-TTLS tunnel, so `web.certificate.get` cannot reach it. Check the file on the host:

```ini
UserParameter=radius.cert.expiry[*],openssl x509 -enddate -noout -in "$1" | cut -d= -f2 | xargs -I{} date -d {} +%%s
```

Item `radius.cert.expiry[/etc/letsencrypt/live/radius.example.com/fullchain.pem]`,
interval 1h:

```
(last(/RADIUS/radius.cert.expiry[...]) - now()) / 86400 < 14
```

If the same certificate is also served by a web server on 443, the stock
`web.certificate.get[radius.example.com,443]` item is simpler and needs no UserParameter.

Expiry and `CERT_RELOAD_WATCH` are separate concerns: expiry means the renewal never
happened; a stale served certificate means the renewal happened and the container did not
pick it up. Only an end-to-end EAP test catches the second.

## 6. Optional: synthetic end-to-end check

The strongest single signal is a real EAP-TTLS authentication with a dedicated test
account, run as a Zabbix external check every 5 minutes with `eapol_test` (see
`test/e2e/`). It validates the certificate chain, the tunnel, the proxy leg and authentik
in one item — including the stale-certificate case nothing else detects.

It also parks a live credential on the monitoring host. Scope that account to nothing,
exclude it from any VLAN assignment, and rotate it.

## Verify before building items

Run each collector by hand; all of these should print data:

```bash
docker exec freeradius sh -c 'printf "Message-Authenticator = 0x00\nFreeRADIUS-Statistics-Type = All\n" | /opt/bin/radclient -x -t 2 -r 1 127.0.0.1:18121 status "$(cat /run/radiusd/healthcheck.secret)"'
/usr/local/bin/zbx_radius_stats.sh freeradius
curl -s 127.0.0.1:9300/metrics | head
zabbix_agent2 -t 'freeradius.stats[freeradius]'
```

`zabbix_agent2 -t` runs as the invoking user, not as `zabbix`. If it works as root but the
item stays unsupported, the agent user is missing Docker access.
