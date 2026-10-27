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

**Applications → Outposts → Create.** Type **RADIUS**, assign the application. Open the
outpost from the list: the card **Outpost Deployment Info** shows its token as
`AUTHENTIK_TOKEN`. Copy it into `AUTHENTIK_TOKEN` of this stack.

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

Dynamic VLAN applies to EAP-TTLS only. PEAP users (section 6) get no `Filter-Id` and no
tunnel attributes and always stay in the SSID's VLAN.

Verified against authentik 2026.8.3 with the real RADIUS outpost.

## 6. WiFi password for PEAP (optional)

PEAP-MSCHAPv2 lets every platform join with a username and password and no profile. It
needs the NT hash of the password, which authentik does not keep, so users get a separate,
generated **WiFi password** in the authentik portal. Their SSO password is not involved.

### Import the blueprint

**Customization → Blueprints → Import**, upload
[`authentik/blueprints/wlan-passwort.yaml`](../authentik/blueprints/wlan-passwort.yaml).

| Context key | Default | Meaning |
|---|---|---|
| `wlan_group` | `wlan` | who may get a WiFi password and join; created if missing, never changed |
| `ssid` | `WLAN` | shown to the user |
| `radius_server_name` | `radius.example.com` | the certificate name users must confirm |
| `password_manager` | `Bitwarden` | where the page tells users to store the password |
| `authentik_url` | `https://authentik.example.com` | absolute URL of your authentik, used for the launch URL of the portal tile (authentik rejects a relative one) |
| `ldap_search_group` | `wlan-ldap-search` | who may bind to the LDAP provider |
| `ldap_base_dn` | `dc=ldap,dc=goauthentik,dc=io` | base DN of the LDAP provider |

It creates the flow `wlan-passwort`, the portal tile **WLAN-Zugang**, and the LDAP
provider `wlan-ldap` with its own bind flow. Change the defaults by editing the context
block before the import. Without `authentik_url` the tile points to `authentik.example.com`.

### Service account, permission, outpost

The blueprint does not create these:

1. **Directory → Users → Create Service Account**:
   - Name `svc-wlan-ldap`.
   - Clear **Create group** and **Expiring**. An expired token switches PEAP off without
     warning.
2. Add `svc-wlan-ldap` to the group `wlan-ldap-search`.
3. **Directory → Roles → Create**, name `wlan-ldap-search`. Then:
   - Assign the role to the group `wlan-ldap-search`.
   - On the provider `wlan-ldap` (**Permissions** tab), grant the role
     **Search full LDAP directory**.
4. **Applications → Outposts → Create**:
   - Type **LDAP**, provider `wlan-ldap`, no service connection.
   - Open the outpost from the list: the card **Outpost Deployment Info** shows its token
     as `AUTHENTIK_TOKEN`. Copy it into `AUTHENTIK_LDAP_TOKEN` of this stack.
5. **Directory → Tokens**, token `service-account-svc-wlan-ldap-password` → copy into
   `LDAP_BIND_PASSWORD`.
6. Deploy with [`docker-compose.peap.yml`](../docker-compose.peap.yml) as an additional
   Compose file and set the `LDAP_*` variables from `.env.example`.

The DNs in `LDAP_BASE_DN`, `LDAP_BIND_DN` and `LDAP_WLAN_GROUP_DN` must be a single line of
1-255 characters of `A-Z a-z 0-9 = , . _ -` and spaces. The container refuses to start
otherwise (`<VAR> must be a single line` for a line break, `<VAR> may only contain A-Z a-z
0-9 = , . _ - and spaces` for anything else); `+`, `#`, parentheses and non-ASCII
characters are not accepted, so a group whose DN needs them must be renamed.

**The NT hashes are readable over LDAP.** This provider is not the boundary: authentik
exposes every user attribute as an LDAP attribute, so every LDAP provider in this authentik
hands out `wifi-password-nthash` to its search-permitted accounts. Keep the group
`wlan-ldap-search` to the service account, and do not attach this provider to any other
application. Rotating the token: create a new one for `svc-wlan-ldap`, update
`LDAP_BIND_PASSWORD`, redeploy, delete the old token.

PEAP users are not placed in a VLAN: `VLAN_MAP` (section 5) applies to EAP-TTLS only, and
PEAP users stay in the SSID's VLAN.

### What users and the helpdesk do

- **Users:** open **WLAN-Zugang** in the portal, store the six-word password in the password
  manager, confirm.
  Getting a new one invalidates the old one on every device.
- **Stale page:** submitting an outdated WiFi password page, for example a second tab after
  a password was already saved, is refused with "Das WLAN-Passwort ist abgelaufen. Bitte
  lade die Seite neu." Reloading the page shows a new password; nothing is saved from the
  stale page.
- **Known gap:** one case is not caught. Tabs A and B show the same password; B saves it
  and is reloaded, which shows a new, unsaved password. If A is submitted now, the new
  password is saved while A still shows the old one, and the password stored from A does
  not work. authentik replaces the values of read-only and hidden prompt fields with the
  server's before the validation policy runs, so the server cannot tell which page was
  submitted. Remedy: fetch a new password in the portal.
- **Helpdesk:** cannot read a WiFi password back, because the passphrase itself is never
  stored. The hash is a plain user attribute, though: anyone who may edit user attributes
  can replace it, and the blueprint does not restrict that. Deleting
  `wifi-password-nthash` on the user locks WiFi until the user fetches a new one.
- **Leavers:** deactivating the user, or removing them from `wlan`, refuses the next
  login. No cache is involved: the provider runs in `direct` mode. A device that is already
  connected stays connected until it authenticates again (reconnect, roaming, or the
  session timeout the access points enforce); nothing sends a Disconnect-Request. The same
  holds for a replaced WiFi password. To cut off a lost device at once, disconnect it on
  the access point or controller.

### Security

- The NT hash is equivalent to the WiFi password: anyone with the authentik database, an
  admin account or the service account token has WiFi access for every user — not their
  SSO account.
- Every LDAP provider in this authentik exposes `wifi-password-nthash` to the accounts that
  may search it, whatever the provider is for. Before rollout, audit the existing LDAP
  providers (NAS, Nextcloud and the like) and their service accounts, and do not give
  "Search full LDAP directory" to an account that does not need it.
- Without a profile users confirm the server certificate by tapping. A fake access point
  can record the exchange and recover the NT hash offline (about 2^56 DES operations).
  Tell users the certificate name; managed devices should still get a profile.
- The plaintext passphrase sits in the user's session until it is saved or the session
  expires. On saving, the flow also drops it from the prompt data, so the flow history
  authentik keeps in the session does not hold it either (checked by the integration test).
- Only the `wlan-passwort` flow may write `wifi-password-nthash`. Do not add a prompt field
  named `attributes.wifi-password-*` to any user-facing flow (enrollment, profile edit):
  users could then set the hash to a value of their choosing and the guarantee is gone.
