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
