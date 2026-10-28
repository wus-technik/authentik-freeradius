#!/usr/bin/env bash
# End-to-end test for the EAP-TTLS -> inner PAP -> authentik proxy chain.
#
# The recovery case is the important one: with status_check = status-server a
# dead home server never revives, because the authentik outpost never answers
# Status-Server. That fault passes `radiusd -XC` without complaint, so only a
# live outage test catches it. See spec section 4.12.
set -euo pipefail

# Git Bash on Windows rewrites container-side paths otherwise.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.test.yml)
REVIVE_WAIT="${REVIVE_WAIT:-75}"

cleanup() {
	docker rm -f akfr-e2e-nopeap akfr-e2e-outside >/dev/null 2>&1 || true
	"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Extra arguments (e.g. -e VAR=value) go to `docker compose run`; most callers pass none.
# shellcheck disable=SC2119,SC2120
auth() { "${COMPOSE[@]}" run --rm --quiet-pull "$@" client >/dev/null 2>&1; }

service_ip() {
	docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
		"$("${COMPOSE[@]}" ps -q "$1")"
}

started_at() {
	docker inspect --format '{{.State.StartedAt}}' "$("${COMPOSE[@]}" ps -q "$1")"
}

# rejects <expected message> VAR=value...: freeradius must refuse to start with
# these variables and say why. timeout keeps a regression -- a container that
# starts after all -- from hanging the suite.
rejects() {
	expect="$1"
	shift
	args=()
	for kv in "$@"; do args+=(-e "$kv"); done
	rc=0
	out="$(timeout 60 "${COMPOSE[@]}" run --rm --no-deps "${args[@]}" freeradius 2>&1)" || rc=$?
	[ "$rc" -ne 0 ] || fail "freeradius started with $*; expected it to refuse: $expect"
	[ "$rc" -ne 124 ] || fail "freeradius kept running for 60s with $*; it must refuse promptly: $expect"
	[ "$rc" -le 128 ] || fail "freeradius was killed (exit $rc) with $*; it must refuse by itself: $expect"
	grep -qF "$expect" <<<"$out" \
		|| fail "freeradius refused $* without saying '$expect'. Output: $out"
}

echo "== building =="
"${COMPOSE[@]}" build --quiet
"${COMPOSE[@]}" run --rm certgen >/dev/null

echo "== starting stack =="
"${COMPOSE[@]}" up -d authentik_radius authentik_ldap freeradius
sleep 10

echo "== baseline authentication =="
auth || fail "baseline EAP-TTLS authentication did not succeed"
echo "   ok"

echo "== dynamic VLAN from Filter-Id =="
# The stand-in returns Filter-Id the way an authentik property mapping does;
# VLAN_MAP in docker-compose.test.yml maps vlan-staff to 20 (issue #10).
reply() {
	"${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_USER="$1" -e AUTH_DUMP=1 client 2>/dev/null \
		| sed -n '/code=2 (Access-Accept)/,/^[^ ]/p'
}
mapped="$(reply testuser)"
[ -n "$mapped" ] || fail "no Access-Accept for testuser"
grep -A1 'Attribute 64 (Tunnel-Type)' <<<"$mapped" | grep -q 'Value: 0000000d' \
	|| fail "Tunnel-Type = VLAN missing from the outer Access-Accept"
grep -A1 'Attribute 65 (Tunnel-Medium-Type)' <<<"$mapped" | grep -q 'Value: 00000006' \
	|| fail "Tunnel-Medium-Type = IEEE-802 missing from the outer Access-Accept"
grep -A1 'Attribute 81 (Tunnel-Private-Group-Id)' <<<"$mapped" | grep -q 'Value: 3230$' \
	|| fail "Tunnel-Private-Group-Id = 20 missing from the outer Access-Accept"
unmapped="$(reply otheruser)"
[ -n "$unmapped" ] || fail "no Access-Accept for otheruser"
if grep -q 'Attribute 81 ' <<<"$unmapped"; then
	fail "an unmapped Filter-Id name produced a VLAN; it must fall back to the SSID's VLAN"
fi
if grep -q 'Attribute 11 (Filter-Id)' <<<"$mapped"$'\n'"$unmapped"; then
	fail "Filter-Id leaked to the access point"
fi
echo "   ok"

# ttls_refused <user> [docker compose run args]: the attempt must end in an
# Access-Reject, not in a client that never got an answer.
ttls_refused() {
	local user="$1" out rc=0
	shift
	out="$("${COMPOSE[@]}" run --rm --quiet-pull "$@" -e AUTH_USER="$user" -e AUTH_DUMP=1 client 2>&1)" || rc=$?
	[ "$rc" -ne 0 ] || fail "EAP-TTLS accepted '$user'"
	grep -q 'code=3 (Access-Reject)' <<<"$out" 		|| fail "EAP-TTLS for '$user' failed without an Access-Reject: $(tail -3 <<<"$out")"
}

echo "== EAP-TTLS with user@domain and DOMAIN\user (USERNAME_STRIP_*=true) =="
# The domain is ignored whichever it is (issue #8); the stand-in only knows
# "testuser", so an Accept proves the name was stripped before proxying.
for u in testuser@example.com testuser@other.example.org 'EXAMPLE\testuser' 'OTHER\testuser'; do
	auth -e AUTH_USER="$u" || fail "EAP-TTLS rejected '$u'"
done
for u in testuser@ @example.com testuser@a@b "EXAMPLE\\" '\testuser' 'A\B\testuser' 'EXAMPLE\testuser@example.com'; do
	ttls_refused "$u"
done
echo "   ok"

echo "== outage: stopping the outpost =="
"${COMPOSE[@]}" stop authentik_radius >/dev/null

# The home server must actually reach the "dead" state before recovery is
# tested -- status checks only run against a dead home server, so restarting
# the backend while it is merely "zombie" lets a broken status_check pass.
# Wait for the state transition in the log rather than guessing at a sleep.
deadline=$(( $(date +%s) + 120 ))
while :; do
	auth || true
	if "${COMPOSE[@]}" logs freeradius 2>&1 | grep -q 'as dead'; then
		break
	fi
	[ "$(date +%s)" -lt "$deadline" ] || fail "home server never reached the dead state within 120s; the outage test cannot prove anything"
	sleep 5
done
echo "   home server is dead, as required"

if auth; then fail "authentication succeeded while the outpost was stopped"; fi
echo "   ok (correctly failing)"

echo "== recovery: restarting the outpost =="
"${COMPOSE[@]}" start authentik_radius >/dev/null
sleep "$REVIVE_WAIT"
if ! auth; then
	echo "--- freeradius log ---" >&2
	"${COMPOSE[@]}" logs freeradius 2>&1 | grep -iE 'zombie|dead|alive' >&2 || true
	fail "home server never revived after the outpost came back. \
Check that status_check = none in freeradius/clients.conf -- with status-server \
it can never revive, because the authentik outpost does not answer Status-Server."
fi
echo "   ok"

echo "== outpost recreated alone keeps its address =="
# An image update replaces the outpost container. With a fixed address it comes
# back where radiusd expects it, so authentication resumes without a radiusd
# restart (issue #15).
before="$(started_at freeradius)"
"${COMPOSE[@]}" rm -sf authentik_radius >/dev/null 2>&1
"${COMPOSE[@]}" up -d --no-deps authentik_radius >/dev/null 2>&1
ip="$(service_ip authentik_radius)"
[ "$ip" = 172.28.0.10 ] || fail "the outpost came back on '$ip', not on its fixed 172.28.0.10"
deadline=$(( $(date +%s) + 90 ))
until auth; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "authentication did not resume within 90s after the outpost was recreated"
	sleep 5
done
[ "$(started_at freeradius)" = "$before" ] || fail "radiusd restarted although the outpost kept its address"
echo "   ok"

echo "== configuration the entrypoint must refuse =="
rejects "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address" AUTHENTIK_RADIUS_HOST=authentik_radius
rejects "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address" AUTHENTIK_RADIUS_HOST=172.28.0.010
rejects "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address" AUTHENTIK_RADIUS_HOST=172.28.0.256
peap_on=(PEAP_ENABLE=true LDAP_HOST=172.28.0.11
	"LDAP_BASE_DN=dc=ldap,dc=goauthentik,dc=io"
	"LDAP_BIND_DN=cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io"
	'LDAP_BIND_PASSWORD=e2e-ldap-"bind\n%{User-Name} not-a-real-one'
	"LDAP_WLAN_GROUP_DN=cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io")
rejects "USERNAME_STRIP_DOMAIN must be true or false" USERNAME_STRIP_DOMAIN=yes
rejects "USERNAME_STRIP_DOMAIN must be true or false" 'USERNAME_STRIP_DOMAIN=true" || "'
rejects "USERNAME_STRIP_NTDOMAIN must be true or false" USERNAME_STRIP_NTDOMAIN=1
rejects "PEAP_ENABLE must be true or false" PEAP_ENABLE=yes
rejects "PEAP_ENABLE=true requires LDAP_BIND_PASSWORD" "${peap_on[@]}" LDAP_BIND_PASSWORD=
rejects "LDAP_HOST must be a literal IPv4 address" "${peap_on[@]}" LDAP_HOST=authentik_ldap
rejects "LDAP_WLAN_GROUP_DN may only contain" "${peap_on[@]}" "LDAP_WLAN_GROUP_DN=cn=wlan(x),ou=groups,dc=ldap,dc=goauthentik,dc=io"
rejects "LDAP_BASE_DN may only contain" "${peap_on[@]}" "LDAP_BASE_DN=dc=%{User-Name},dc=io"
rejects "LDAP_BIND_DN may only contain" "${peap_on[@]}" 'LDAP_BIND_DN=cn=svc"wlan,ou=users,dc=ldap,dc=goauthentik,dc=io'
rejects "LDAP_PORT must be a port number" "${peap_on[@]}" LDAP_PORT=3389x
for port in 0 03389 65536 99999999999999999999; do
	rejects "LDAP_PORT must be 1-65535" "${peap_on[@]}" LDAP_PORT="$port"
done
echo "   ok"

echo "== client networks and site secrets the entrypoint must refuse =="
rejects "RADIUS_CLIENT_NET must not contain 0.0.0.0/0" "RADIUS_CLIENT_NET=172.28.0.0/17=infra,0.0.0.0/0=infra"
rejects "RADIUS_CLIENT_NET must not contain ::/0" "RADIUS_CLIENT_NET=::/0=infra"
for net in 172.28.0.0/33 172.28.0.256/24 172.28.0.0/ 172.28.0.0/017 radius.example.com; do
	rejects "RADIUS_CLIENT_NET: '$net' is not an IPv4/IPv6 address or network" "RADIUS_CLIENT_NET=$net=infra"
done
rejects "RADIUS_CLIENT_NET lists 172.28.0.0/17 twice" "RADIUS_CLIENT_NET=172.28.0.0/17=infra,172.28.0.0/17=infra"
rejects "RADIUS_CLIENT_NET lists no network" "RADIUS_CLIENT_NET= , "
rejects "172.28.0.0/17 names no site, so RADIUS_SECRET is required" "RADIUS_CLIENT_NET=172.28.0.0/17"
rejects "site 'nosuch' of 172.28.0.0/17 has no secret in RADIUS_SITE_SECRETS" "RADIUS_CLIENT_NET=172.28.0.0/17=nosuch"
rejects "RADIUS_SITE_SECRETS: site 'infra' has no network in RADIUS_CLIENT_NET" "RADIUS_CLIENT_NET=172.28.128.0/17=clients"
rejects "RADIUS_SITE_SECRETS: expected site:secret" "RADIUS_SITE_SECRETS=infra"
rejects "RADIUS_SITE_SECRETS: site name 'in-fra'" "RADIUS_SITE_SECRETS=in-fra:e2e-infra-site-secret-not-a-real-one"
rejects "RADIUS_SITE_SECRETS: site 'infra' is listed twice" "RADIUS_SITE_SECRETS=infra:e2e-infra-site-secret-not-a-real-one,infra:e2e-infra-site-secret-not-a-real-two"
rejects "the secret of site 'infra' in RADIUS_SITE_SECRETS still holds the placeholder" "RADIUS_SITE_SECRETS=infra:CHANGEME-run-openssl-rand-hex-32,clients:e2e-uplink-secret-not-a-real-one"
rejects "the secret of site 'clients' in RADIUS_SITE_SECRETS must be at least 16 characters" "RADIUS_SITE_SECRETS=infra:e2e-infra-site-secret-not-a-real-one,clients:tooshort-1"
# The refusal names the site, never the secret.
if grep -qF tooshort-1 <<<"$out"; then fail "the entrypoint printed a site secret: $out"; fi
echo "   ok"

echo "== each network uses its own site's secret =="
# The client sits in "clients"; the secret of "infra" must not work for it.
# No answer, not a reject: radiusd drops a packet with a wrong secret.
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if auth -e RADIUS_SECRET=e2e-infra-site-secret-not-a-real-one -e AUTH_TIMEOUT=5; then
	fail "the secret of site infra was accepted from the clients network"
fi
"${COMPOSE[@]}" logs --since "$since" freeradius 2>&1 | grep -qi 'Message-Authenticator' \
	|| fail "no Message-Authenticator error logged for the wrong site secret"
# No secret ever reaches the log.
if "${COMPOSE[@]}" logs freeradius 2>&1 | grep -qF 'not-a-real-one'; then
	fail "a secret appears in the freeradius log"
fi
echo "   ok"

echo "== a network outside RADIUS_CLIENT_NET is ignored =="
"${COMPOSE[@]}" run -d --no-deps --name akfr-e2e-outside \
	-e RADIUS_CLIENT_NET=172.28.0.0/17=infra \
	-e RADIUS_SITE_SECRETS=infra:e2e-infra-site-secret-not-a-real-one freeradius >/dev/null
sleep 10
if auth -e AUTH_TARGET=akfr-e2e-outside -e AUTH_TIMEOUT=5; then
	fail "a client outside every network in RADIUS_CLIENT_NET was answered"
fi
docker logs akfr-e2e-outside 2>&1 | grep -q 'unknown client' \
	|| fail "no 'unknown client' line for a client outside RADIUS_CLIENT_NET"
docker rm -f akfr-e2e-outside >/dev/null
echo "   ok"

peap() { auth -e AUTH_METHOD=peap -e AUTH_USER="$1" -e AUTH_PASSWORD="$2"; }

# peap_refused <user> <password> [docker compose run args]: the attempt must end
# in an Access-Reject. A client that cannot start or a server that never answers
# also "does not succeed", and would pass a plain negative check.
peap_refused() {
	local user="$1" password="$2" out rc=0
	shift 2
	out="$("${COMPOSE[@]}" run --rm --quiet-pull "$@" -e AUTH_METHOD=peap -e AUTH_USER="$user" \
		-e AUTH_PASSWORD="$password" -e AUTH_DUMP=1 client 2>&1)" || rc=$?
	[ "$rc" -ne 0 ] || fail "PEAP accepted '$user' with password '$password'"
	grep -q 'code=3 (Access-Reject)' <<<"$out" \
		|| fail "PEAP for '$user' failed without an Access-Reject: $(tail -3 <<<"$out")"
}

echo "== PEAP-MSCHAPv2 against the LDAP outpost =="
peap peapuser e2e-peap-pw || fail "PEAP with the right WiFi password was rejected"
peap_refused peapuser wrong-password
for u in peapinactive peapnogroup peapnohash; do
	peap_refused "$u" e2e-peap-pw
done
# Each refusal must come from the directory filter, not from a later failure.
# The line ends with the user name, so anchor on it: no user matches another's
# line. [[:space:]]* allows for a trailing carriage return in the log output.
peap_log="$("${COMPOSE[@]}" logs freeradius 2>&1)"
for u in peapinactive peapnogroup peapnohash; do
	grep -qE "peap: no active WLAN user with a WiFi password: ${u}[[:space:]]*\$" <<<"$peap_log" \
		|| fail "no log line for the refused PEAP login of $u"
done
grep -qE "peap: wrong WiFi password: peapuser[[:space:]]*\$" <<<"$peap_log" \
	|| fail "no log line for the wrong PEAP password of peapuser"
# MSCHAPv2 hashes the name the client typed: the stripped name may only be
# used for the lookup, or this Accept turns into a wrong-password reject.
# For DOMAIN\user the client drops the domain before hashing, and so must mschap.
for u in peapuser@example.com 'EXAMPLE\peapuser'; do
	peap "$u" e2e-peap-pw || fail "PEAP rejected '$u'"
	peap_refused "$u" wrong-password
done
peap_refused peapinactive@example.com e2e-peap-pw
peap_refused 'EXAMPLE\peapinactive' e2e-peap-pw
# User-Name goes into an LDAP filter; metacharacters must not widen it, and
# neither may they once the domain is stripped off.
for u in '*' 'peapuser)(cn=*' 'peap*' '*@example.com' 'peap*@example.com' 'peapuser)(cn=*@example.com' 'EXAMPLE\*' 'EXAMPLE\peap*'; do
	peap_refused "$u" e2e-peap-pw
done
echo "   ok"

echo "== nothing from inside the PEAP tunnel reaches the access point =="
accept="$("${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_METHOD=peap -e AUTH_DUMP=1 client 2>/dev/null \
	| sed -n '/code=2 (Access-Accept)/,/^[^ ]/p')"
[ -n "$accept" ] || fail "no Access-Accept for peapuser"
# Positive control: the MPPE keys (Microsoft vendor 311 = 0x137, type 16/17)
# must be there, or the pattern below proves nothing.
grep -qi 'Value: 0000013710' <<<"$accept" \
	|| fail "MS-MPPE-Send-Key missing from the outer Access-Accept"
# MS-CHAP2-Success is vendor 311 type 26 (0x1a). It belongs inside the tunnel.
if grep -qi 'Value: 000001371a' <<<"$accept"; then
	fail "MS-CHAP2-Success from inside the tunnel leaked into the outer Access-Accept"
fi
# eap_mschapv2 strips MS-CHAP2-Success itself, so the check above holds even
# with use_tunneled_reply = yes. What that setting does let through is the
# inner User-Name: the outer reply then names the inner identity instead of the
# anonymous outer one. That is the pattern that fails on a regression.
if grep -q "Value: 'peapuser'" <<<"$accept"; then
	fail "the inner identity from inside the tunnel leaked into the outer Access-Accept"
fi
grep -q "Value: 'anonymous'" <<<"$accept" \
	|| fail "the outer User-Name (anonymous) is missing from the Access-Accept"
echo "   ok"

echo "== PEAP while the LDAP outpost is down =="
"${COMPOSE[@]}" stop authentik_ldap >/dev/null
start=$(date +%s)
peap_refused peapuser e2e-peap-pw
took=$(( $(date +%s) - start ))
[ "$took" -le 15 ] || fail "PEAP took ${took}s to fail with the LDAP outpost down; it must fail fast"
auth || fail "EAP-TTLS failed while only the LDAP outpost was down"
echo "   ok (PEAP refused in ${took}s, EAP-TTLS unaffected)"

echo "== radiusd restarted while the LDAP outpost is down =="
"${COMPOSE[@]}" restart freeradius >/dev/null
deadline=$(( $(date +%s) + 60 ))
until auth; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "radiusd did not come back without the LDAP outpost"
	sleep 3
done
peap_refused peapuser e2e-peap-pw
echo "   ok"

echo "== LDAP outpost back, no radiusd restart =="
before="$(started_at freeradius)"
"${COMPOSE[@]}" start authentik_ldap >/dev/null
deadline=$(( $(date +%s) + 60 ))
until peap peapuser e2e-peap-pw; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "PEAP did not recover after the LDAP outpost came back"
	sleep 3
done
[ "$(started_at freeradius)" = "$before" ] || fail "radiusd restarted to reconnect to LDAP; it must not"
echo "   ok"

echo "== LDAP outpost recreated keeps its address =="
"${COMPOSE[@]}" rm -sf authentik_ldap >/dev/null 2>&1
"${COMPOSE[@]}" up -d --no-deps authentik_ldap >/dev/null 2>&1
ip="$(service_ip authentik_ldap)"
[ "$ip" = 172.28.0.11 ] || fail "the LDAP outpost came back on '$ip', not on its fixed 172.28.0.11"
deadline=$(( $(date +%s) + 60 ))
until peap peapuser e2e-peap-pw; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "PEAP did not recover after the LDAP outpost was recreated"
	sleep 3
done
[ "$(started_at freeradius)" = "$before" ] || fail "radiusd restarted after the LDAP outpost was recreated"
echo "   ok"

echo "== PEAP and USERNAME_STRIP_* switched off, one network without sites =="
# A dedicated container with PEAP_ENABLE=false and no LDAP variables at all:
# PEAP must be refused, EAP-TTLS must work as before (spec 8.1). It also runs
# the single-network form without sites, as every deployment before issue #4.
"${COMPOSE[@]}" run -d --no-deps --name akfr-e2e-nopeap \
	-e PEAP_ENABLE=false -e LDAP_HOST= -e LDAP_BASE_DN= -e LDAP_BIND_DN= \
	-e LDAP_BIND_PASSWORD= -e LDAP_WLAN_GROUP_DN= -e USERNAME_STRIP_DOMAIN=false \
	-e USERNAME_STRIP_NTDOMAIN=false -e RADIUS_CLIENT_NET=172.28.0.0/16 -e RADIUS_SITE_SECRETS= \
	-e 'RADIUS_SECRET=e2e-uplink-"sec\ret%{User-Name} not-a-real-one' freeradius >/dev/null
deadline=$(( $(date +%s) + 60 ))
until auth -e AUTH_TARGET=akfr-e2e-nopeap; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "EAP-TTLS failed against the container with PEAP switched off"
	sleep 3
done
peap_refused peapuser e2e-peap-pw -e AUTH_TARGET=akfr-e2e-nopeap
# This container also runs with both USERNAME_STRIP_* off: the domain stays.
ttls_refused testuser@example.com -e AUTH_TARGET=akfr-e2e-nopeap
ttls_refused 'EXAMPLE\testuser' -e AUTH_TARGET=akfr-e2e-nopeap
docker rm -f akfr-e2e-nopeap >/dev/null
echo "   ok"

echo "== container healthcheck =="
cid="$("${COMPOSE[@]}" ps -q freeradius)"
[ -n "$cid" ] || fail "freeradius container is not running"
# The container may still be inside its start period, or unhealthy for a moment
# after the outpost stages. Wait for a verdict rather than reading "starting" as a failure.
deadline=$(( $(date +%s) + 90 ))
while :; do
	health="$(docker inspect --format '{{.State.Health.Status}}' "$cid")"
	[ "$health" = "starting" ] || break
	[ "$(date +%s)" -lt "$deadline" ] || break
	sleep 5
done
[ "$health" = "healthy" ] || fail "freeradius container health is '${health:-unknown}', expected 'healthy'"
echo "   ok"

echo
echo "PASS: all end-to-end checks succeeded"
