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

**RADIUS Assigned VLAN** — enable it only once `VLAN_MAP` is set and the authentik mapping
from [authentik.md § 5](authentik.md#5-dynamic-vlan-optional) is in place. Users without a
mapped name then stay in the SSID's own VLAN. The uplink to each AP must carry every VLAN
that `VLAN_MAP` can hand out, tagged, or those clients associate and get no DHCP lease.

## SSID

**Settings → WiFi → Create New.**

| Field | Value |
|---|---|
| Security Protocol | `WPA2 Enterprise` (or `WPA3 Enterprise` / `WPA2/WPA3` if all clients support it) |
| RADIUS Profile | `authentik` |

WPA3-Enterprise requires Protected Management Frames and is not supported by older clients.
Start with WPA2 Enterprise, confirm it works, then move up.

**An SSID does not pin the EAP method.** The controller configures WPA-Enterprise and a
RADIUS profile, nothing more; which EAP type runs is negotiated between the supplicant and
FreeRADIUS. One SSID can therefore carry an EAP-TTLS/PAP rollout and an EAP-TLS pilot at
the same time, and moving a device between them is a client-side profile change with
nothing to do on the controller.

## Firewall

The APs must reach the Docker host on **UDP 1812**. `RADIUS_CLIENT_NET` must cover the AP
and controller addresses, or FreeRADIUS drops the packets as coming from an unknown client
— visible in the log as `Ignoring request ... from unknown client`.
