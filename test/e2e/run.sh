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
	docker rm -f akfr-e2e-nopeap >/dev/null 2>&1 || true
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
	if out="$(timeout 60 "${COMPOSE[@]}" run --rm --no-deps "${args[@]}" freeradius 2>&1)"; then
		fail "freeradius started with $*; expected it to refuse: $expect"
	fi
	printf '%s\n' "$out" | grep -qF "$expect" \
		|| fail "freeradius refused $* without saying '$expect'. Output: $out"
}

echo "== building =="
"${COMPOSE[@]}" build --quiet
"${COMPOSE[@]}" run --rm certgen >/dev/null

echo "== starting stack =="
"${COMPOSE[@]}" up -d authentik_radius freeradius
sleep 10

echo "== baseline authentication =="
auth || fail "baseline EAP-TTLS authentication did not succeed"
echo "   ok"

echo "== dynamic VLAN from Filter-Id =="
# The stand-in returns Filter-Id the way an authentik property mapping does;
# VLAN_MAP in docker-compose.test.yml maps vlan-staff to 20 (issue #10).
reply() {
	"${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_USER="$1" -e AUTH_DUMP=1 client 2>/dev/null 		| sed -n '/code=2 (Access-Accept)/,/^[^ ]/p'
}
mapped="$(reply testuser)"
[ -n "$mapped" ] || fail "no Access-Accept for testuser"
printf '%s
' "$mapped" | grep -A1 'Attribute 64 (Tunnel-Type)' | grep -q 'Value: 0000000d' 	|| fail "Tunnel-Type = VLAN missing from the outer Access-Accept"
printf '%s
' "$mapped" | grep -A1 'Attribute 65 (Tunnel-Medium-Type)' | grep -q 'Value: 00000006' 	|| fail "Tunnel-Medium-Type = IEEE-802 missing from the outer Access-Accept"
printf '%s
' "$mapped" | grep -A1 'Attribute 81 (Tunnel-Private-Group-Id)' | grep -q 'Value: 3230$' 	|| fail "Tunnel-Private-Group-Id = 20 missing from the outer Access-Accept"
unmapped="$(reply otheruser)"
[ -n "$unmapped" ] || fail "no Access-Accept for otheruser"
if printf '%s
' "$unmapped" | grep -q 'Attribute 81 '; then
	fail "an unmapped Filter-Id name produced a VLAN; it must fall back to the SSID's VLAN"
fi
if printf '%s
%s
' "$mapped" "$unmapped" | grep -q 'Attribute 11 (Filter-Id)'; then
	fail "Filter-Id leaked to the access point"
fi
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
echo "   ok"

echo "== container healthcheck =="
cid="$("${COMPOSE[@]}" ps -q freeradius)"
[ -n "$cid" ] || fail "freeradius container is not running"
# Stage 4 restarted radiusd, so the container may still be inside its start
# period. Wait for a verdict rather than reading "starting" as a failure.
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
