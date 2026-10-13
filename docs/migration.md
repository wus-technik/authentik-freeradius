# Replacing an existing PEAP/MSCHAPv2 RADIUS

Most WPA-Enterprise deployments this stack replaces look the same: FreeRADIUS (often the
Synology *RADIUS Server* package, or NPS) doing **PEAP/MSCHAPv2 against Active Directory**,
with the domain controller's own CA issuing the EAP server certificate.

**Two ways across, with different client cost:**

- **PEAP-MSCHAPv2 with a WiFi password** ([authentik.md § 6](authentik.md#6-wifi-password-for-peap-optional)).
  The inner method stays MSCHAPv2, so clients need no new profile — but every user needs a
  new *password*: the generated WiFi password replaces the AD password for WiFi. Plan a
  mail with the portal link (template: [rollout-mail.de.md](rollout-mail.de.md)) and keep
  the old server running until users have switched. No AD, no `ntlm_auth`.
- **EAP-TTLS/PAP or EAP-TLS.** The inner method changes, so **every client needs a new
  profile**. Plan the rollout mechanism (Intune, GPO, `.mobileconfig`, NetworkManager)
  before the cutover, not after.

## Survey the old server first

Write down what it actually does, not what you assume it does. The answers decide which of
the open issues are blockers for you and which are cosmetic.

| Question | Where to look (FreeRADIUS 3.x) | Why it matters |
|---|---|---|
| Is there an **accounting** listener? | a `listen { type = acct }` block; is UDP 1813 open? | No acct on the old server means [#1](https://github.com/wus-technik/authentik-freeradius/issues/1) is not a migration blocker. |
| Are any **reply attributes** returned? | `post-auth`, `users`/`rad_users`, `mods-enabled/attr_filter` | If the VLAN comes from the SSID and nothing else is returned, [#2](https://github.com/wus-technik/authentik-freeradius/issues/2) is not a blocker — and the replacement must **not** start returning tunnel attributes, or SSID behaviour changes. |
| Is there a **user filter**? | group checks in `authorize`, `files`, LDAP group filters | Many AD setups have **none**: every domain account may join. An authentik flow with a group binding is stricter. That is usually the point, but it is a behaviour change — agree it before cutover or people are locked out ([#9](https://github.com/wus-technik/authentik-freeradius/issues/9)). |
| How are **realms** handled? | `suffix`/`ntdomain` in `authorize`, `with_ntdomain_hack` | If the old server strips both `DOMAIN\user` and `user@domain`, clients have those forms saved. The replacement must keep accepting them ([#8](https://github.com/wus-technik/authentik-freeradius/issues/8)). |
| Which **clients** are defined? | `clients.conf` and its includes | Note the `ipaddr`/netmask of each. Whole `/24`s are common. |
| Does one **secret** cover all of them? | the same `secret =` repeated | Very common, and worth not reproducing — see below. |

## Client networks and secrets

An old server with six subnet clients is six entire `/24`s allowed to send requests, often
all sharing one secret. Do not carry that over:

- Give **each site its own shared secret.** One leaked AP then costs one site, not the
  estate.
- Scope each client as tightly as the controller architecture allows.

This stack currently takes a **single** `RADIUS_CLIENT_NET`. If the old server has more
than one active client network — and a multi-site WiFi almost always does — that is a
hard blocker, tracked as [#4](https://github.com/wus-technik/authentik-freeradius/issues/4).

## The certificate is the real work

This is where migrations stall. A typical AD-issued EAP certificate looks like:

- `CN=<server>.<ad domain>`, **no SAN**
- issued by the **self-signed directory CA**, valid for ten years
- present in every correctly-configured supplicant's trust settings, often pinned by name

A public certificate (Let's Encrypt, `radius.example.com`) changes **both** the issuer and
the CN. Clients that validate the server — which is to say, every correctly configured
client — will refuse it. There are two honest options:

1. **Carry the old certificate and key over** (`fullchain.pem` + `privkey.pem` into
   `LETSENCRYPT_DIR`). The name and issuer stay put, and the migration needs no client
   changes for trust. Check what else on the old box is bound to that certificate — the
   same file is frequently also serving FTPS, VPN or LDAPS, so rotating it later touches
   several services at once.
2. **Use a new public certificate and re-profile every client.** More work up front, but
   the profile push is needed anyway for the inner-method change — and once you are
   pushing profiles, EAP-TLS becomes the better destination ([#7](https://github.com/wus-technik/authentik-freeradius/issues/7)).

Whichever you pick, read [docs/certificates.md](certificates.md) for the rotation
mechanics, and do not point `ca_file` at a CA that issues anything other than WLAN client
certificates: `ca_file` makes **every** certificate from that CA a valid WLAN credential.
Pointing it at a VPN or corporate CA silently turns every VPN client certificate into a
WiFi pass.

## Cutover checklist

- [ ] Old server surveyed; the table above answered in writing.
- [ ] Certificate decision made (carry over, or new + client rollout).
- [ ] Every active client network covered, each with its own secret.
- [ ] Realm forms the old server accepted still work.
- [ ] Group/flow binding in authentik agreed against the old server's (absent) user filter.
- [ ] One real client of each platform authenticated against the new stack **before**
      the old server is touched.
- [ ] With PEAP: users told, WiFi passwords fetched, one device per platform (Windows,
      iOS, macOS, Android) joined without a profile.
- [ ] Old server left running and reachable until the new one has carried production load.
