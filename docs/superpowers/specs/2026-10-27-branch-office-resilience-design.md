# Design: WiFi authentication at branch offices that survives site-to-site VPN outages

Date: 2026-10-27
Status: Draft (starter). Options collected, nothing decided yet.
Issues: none yet

## 1. Problem

Branch offices reach the central stack over a site-to-site VPN:

```
Branch AP ──RADIUS/UDP──▶ (site-to-site VPN) ──▶ FreeRADIUS ──▶ authentik RADIUS outpost ──HTTPS──▶ authentik core
```

When the tunnel drops, every new 802.1X authentication at the branch fails. Every login goes
all the way to the authentik core: the RADIUS outpost runs the authentication flow against the
core on every request and cannot authenticate offline. So moving only the outpost to the branch
does not help.

## 2. What actually breaks (to be measured first)

A client that is already connected does not re-authenticate until its session times out or it
roams to another access point. A tunnel drop therefore only hits:

- new connections (device wakes up, arrives in the morning, reconnects after sleep),
- roams between APs without fast roaming,
- clients whose session times out during the outage.

Open: measure outage frequency and duration and the current `Session-Timeout` / roaming
setup before choosing an option. It may be that tuning alone (§ 4.0) covers most cases.

## 3. Goal (draft)

- A user who logged in successfully at a branch recently can still connect there while
  the VPN to the central site is down.
- Disabling a user in authentik takes effect at the branch within a bounded, documented time.
- Every authentication accepted without asking authentik has its own log line.
- An installation without branch nodes behaves exactly as today.

## 4. Options

### 4.0 Tuning only (no new components)

- Longer `Session-Timeout`, fast roaming (802.11r) and PMK caching on the UniFi side.
- Cheapest option. Does not help new connections during an outage.

### 4.1 Keep RADIUS traffic off the tunnel

- A small FreeRADIUS at each branch forwards to the central FreeRADIUS over **RadSec**
  (RADIUS over TLS, TCP 2083) across the internet instead of the site-to-site VPN.
- Variant: a branch outpost talking to the authentik core over its public HTTPS URL.
- Removes the dependency on the tunnel, but not on the branch's internet line or on the central
  site being up.

### 4.2 Credential cache at the branch with fallback

- EAP-TTLS/PAP hands FreeRADIUS the cleartext password, so a branch FreeRADIUS can:
  - after a successful upstream login, store a salted hash of the password with
    `rlm_cache`, with a bounded lifetime (e.g. 24–72 h);
  - if forwarding to authentik fails (`Post-Proxy-Type Fail-Authentication`), check the
    password against the cached hash with the `pap` module and accept it.
- Fits the current config: `freeradius/clients.conf` already forwards through a
  `home_server` / `home_server_pool`. Note `status_check = none` there (the outpost drops
  Status-Server). Its interaction with how and when the fallback fires needs to be worked out.
- PEAP: cache the NT hash from the LDAP lookup in the same way. authentik's LDAP provider also
  has cached bind/search modes; how they behave while the core is unreachable is untested.
- Costs:
  - A disabled user keeps WiFi access at that branch until their cache entry expires.
  - Password hashes sit on the branch host and can be cracked offline if it is compromised.
    This makes the trust model in the README's security section stricter, so the README
    needs its own section on it.
  - Users who never logged in at that branch during the cache lifetime still fail during an
    outage.

### 4.3 EAP-TLS checked locally by FreeRADIUS

- FreeRADIUS checks client certificates against a CA and a cached revocation list (CRL)
  entirely offline, with no authentik round trip. This does not need authentik's
  enterprise-licensed EAP-TLS.
- Cleanest result for outages, but needs a way to roll certificates out to devices (MDM/PKI).
  Revocation is only as current as the last CRL the branch fetched.
- Related: #7/#12 (EAP-TLS, set aside for the PEAP work).

## 5. Initial recommendation

Combine 4.1 and 4.2:

- a branch FreeRADIUS with RadSec to the central one as its main path;
- the cache as a fallback, with a short lifetime and its own log line for every acceptance
  that skipped authentik.

Do 4.0 in any case. Look at 4.3 if device certificates come along for another reason.

## 6. Open questions

- [ ] How often and how long does the VPN actually fail? Which clients are affected (§ 2)?
- [ ] Where does the branch FreeRADIUS run (existing host, small appliance, container on the
      edge device)? How is it deployed and updated: the same image with a "branch" mode, or a
      separate compose file?
- [ ] Do the UniFi APs at the branch get the branch node as primary and the central node as
      secondary, or the branch node only?
- [ ] Cache lifetime, and whether it is set per branch.
- [ ] Hash format in the cache (e.g. SHA-512 crypt) and where the cache lives (in memory vs.
      persistent across restarts).
- [ ] Revocation: is a bounded lag acceptable, or is an explicit flush needed (e.g. triggered
      when a user is disabled)?
- [ ] PEAP: does the NT hash cache follow the same rules, and how does it interact with
      regenerating the WiFi password?
- [ ] Monitoring: alert when a branch is answering from its cache (see `docs/monitoring.md`).
- [ ] Test plan: simulate the tunnel outage in `test/`.

## 7. Non-goals (draft)

- Making authentik itself highly available or replicated per site.
- Disconnect-Request (RFC 5176) for revoking active sessions.
