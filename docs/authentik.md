# authentik configuration

## 1. RADIUS provider

**Applications → Providers → Create → RADIUS Provider.**

| Field | Value |
|---|---|
| Name | `radius-wifi` |
| Authorization flow | an explicit-consent-free flow, e.g. `default-authentication-flow` |
| Client Networks | the Docker network the FreeRADIUS container sits on, e.g. `172.16.0.0/12` |
| Shared secret | the value of `AUTHENTIK_RADIUS_SECRET` |

The shared secret **must** match `AUTHENTIK_RADIUS_SECRET` in the stack exactly. A mismatch
shows up as `No provider found` with a `hashed_secret` field in the outpost log.

Client Networks refers to the FreeRADIUS container's address, not the access points'. The
APs never talk to authentik directly.

## 2. Application

Create an application and bind it to the provider. Bind policies or groups here to control
who may join the WiFi.

## 3. Outpost

**Applications → Outposts → Create.** Type **RADIUS**, assign the application, and copy the
token into `AUTHENTIK_TOKEN`.

If authentik has Docker socket integration enabled it will try to manage its own outpost
container. This stack runs the outpost itself, so use an outpost with no service connection
and let Compose own the container.

## 4. Flow requirements

The flow must complete without user interaction — no MFA prompt, no consent stage. RADIUS
carries a username and a password and nothing else. A flow requiring anything more fails
with `flow error` in the outpost log.

## 5. Dynamic VLAN (optional)

authentik cannot return the tunnel attributes a VLAN needs. Its bundled RADIUS dictionary
does not contain them, and a mapping that sets `Tunnel-Private-Group-Id` fails with
`Failed to evaluate property-mapping`
([goauthentik/authentik#25284](https://github.com/goauthentik/authentik/issues/25284)). It
can return `Filter-Id`, so authentik names a role and FreeRADIUS translates it:

1. **Customization → Property Mappings → Create → RADIUS Provider Property Mapping**:

   ```python
   if ak_is_group_member(request.user, name="wlan-staff"):
       packet["Filter-Id"] = "vlan-staff"
   return packet
   ```

   Use the `packet[...] = ...` form. The `return {"Filter-Id": ...}` form from newer
   authentik docs is silently ignored on 2026.8.

2. Select the mapping on the RADIUS provider.
3. Set `VLAN_MAP=vlan-staff=20` in the stack (several pairs: `vlan-staff=20,vlan-devices=30`)
   and redeploy.
4. Enable **RADIUS Assigned VLAN** in UniFi — see [unifi.md](unifi.md).

FreeRADIUS sets `Tunnel-Type`, `Tunnel-Medium-Type` and `Tunnel-Private-Group-Id` for a
name listed in `VLAN_MAP`. An unlisted name, or no `Filter-Id` at all, returns no tunnel
attributes, so the client stays in the SSID's VLAN. `Filter-Id` itself is never forwarded
to the access point.

Several mappings that each set `Filter-Id` overwrite one another in name order. For a user
in more than one WiFi group, decide the precedence inside a single mapping.

Verified against authentik 2026.8.3 with the real RADIUS outpost.
