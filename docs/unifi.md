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
