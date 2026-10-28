# UniFi configuration

Checked against the Ubiquiti help center as of October 2026 (UniFi Network 10.6, with 11.0
on its way). UniFi Network 11.0 announces a reworked "802.1X and RADIUS settings user
experience", so menu names may have moved again; the fields stay the same.

## RADIUS profile

**Settings → Networks → RADIUS Servers → Create New** (older versions: **Settings →
Profiles → RADIUS**).

| Field | Value |
|---|---|
| Name | `authentik` |
| Authentication Server IP | the Docker host running this stack |
| Authentication Port | `1812` |
| Secret | the site's secret from `RADIUS_SITE_SECRETS`, or `RADIUS_SECRET` (see below) |

Leave accounting off and the accounting server empty. This stack does not implement
accounting; UniFi accounting records would time out. Leave **TLS** (RadSec) off.

**RADIUS Assigned VLAN** — enable it only once `VLAN_MAP` is set and the authentik mapping
from [authentik.md § 5](authentik.md#5-dynamic-vlan-optional) is in place. Users without a
mapped name then stay in the SSID's own VLAN. The uplink to each AP must carry every VLAN
that `VLAN_MAP` can hand out, tagged, or those clients associate and get no DHCP lease.
PEAP users are never placed in a VLAN this way.

## One secret per site

RADIUS profiles belong to a UniFi **site**, like every other Network setting: each site
has its own profiles and its own SSIDs. That is what makes a secret per site possible — a
leaked AP configuration then exposes one site, not the estate.

1. Generate one secret per site: `openssl rand -hex 32`.
2. In the stack, list every AP network with its site and every site with its secret:

   ```
   RADIUS_CLIENT_NET=10.1.0.0/24=hq,10.1.1.0/24=hq,10.2.0.0/24=branch
   RADIUS_SITE_SECRETS=hq:<secret of hq>,branch:<secret of branch>
   ```

   Site names are your own labels (1-32 of `A-Z a-z 0-9 _`) and need not match the UniFi
   site names. Secrets must not contain a comma. A network without `=site` uses
   `RADIUS_SECRET`.
3. In **each** UniFi site, create the RADIUS profile above with **that site's** secret,
   and select it on the site's Enterprise SSID.

The container refuses to start if a network names a site without a secret, a site has no
network, or a secret is weak; its startup log lists which secret each network uses.

**Do not distribute the RADIUS profile with a Fabric.** UniFi Site Manager Fabrics
(*Blueprints*, *Canvas*) can push one SSID and one RADIUS server to many sites — Ubiquiti
names exactly that as a use case. A profile distributed that way carries one secret to every
site and may no longer be editable locally. Keep RADIUS profiles and Enterprise SSIDs out
of any Blueprint or Canvas.

### Switching a live site

FreeRADIUS holds exactly one secret per network, so there is no overlap period: from the
moment the stack is redeployed with a new secret until the UniFi profile carries it, new
logins from that site fail. Do it one site at a time, outside working hours:

1. Change the site's secret in `RADIUS_SITE_SECRETS` and redeploy the stack.
2. Immediately save the new secret in that site's UniFi RADIUS profile. UniFi provisions
   the APs; expect the Enterprise SSID to restart briefly, so connected clients reconnect.
3. Connect one device in that site, and check the FreeRADIUS log for `invalid
   Message-Authenticator` from the site's networks.

Moving from one shared secret to per-site secrets is the same procedure, site by site:
networks still without `=site` keep using `RADIUS_SECRET` until their turn.

## SSID

**Settings → WiFi → Create New.**

| Field | Value |
|---|---|
| Security Protocol | `WPA2 Enterprise` (or `WPA3 Enterprise` / `WPA2/WPA3` if all clients support it) |
| RADIUS Profile | `authentik` (the site's own) |

WPA3-Enterprise requires Protected Management Frames and is not supported by older clients.
Start with WPA2 Enterprise, confirm it works, then move up.

**An SSID does not pin the EAP method.** The controller configures WPA-Enterprise and a
RADIUS profile, nothing more; which EAP type runs is negotiated between the supplicant and
FreeRADIUS. One SSID can therefore carry an EAP-TTLS/PAP rollout and an EAP-TLS pilot at
the same time, and moving a device between them is a client-side profile change with
nothing to do on the controller.

## Firewall and addresses

**The access points send the RADIUS requests themselves**, from their own management
address — not the controller, not the gateway. UniFi has no RADIUS proxy for external
servers. So:

- Every AP must reach the Docker host on **UDP 1812**.
- `RADIUS_CLIENT_NET` must cover the **AP management subnets** of every site. List each
  subnet rather than one supernet: a supernet hands the site's secret to every host in it.
- If traffic from a site is NATed on its way (some site-to-site VPNs), FreeRADIUS sees the
  translated address; list that instead.

An AP outside every listed network is dropped and logged as `Ignoring request ... from
unknown client`.

Every client requires `Message-Authenticator` (BlastRADIUS, CVE-2024-3596). EAP requests
always carry it, so WPA-Enterprise is unaffected; UniFi has no setting for it. MAC
authentication would need its own client block — see `freeradius/clients.conf`.
