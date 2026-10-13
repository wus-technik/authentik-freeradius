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

cleanup() { docker rm -f akfr-e2e-squatter >/dev/null 2>&1 || true; "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

auth() { "${COMPOSE[@]}" run --rm --quiet-pull client >/dev/null 2>&1; }

echo "== building =="
"${COMPOSE[@]}" build --quiet
"${COMPOSE[@]}" run --rm certgen >/dev/null

echo "== starting stack =="
"${COMPOSE[@]}" up -d authentik_radius freeradius
sleep 10

echo "== 1/6 baseline authentication =="
auth || fail "baseline EAP-TTLS authentication did not succeed"
echo "   ok"

echo "== 2/6 dynamic VLAN from Filter-Id =="
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

echo "== 3/6 outage: stopping the outpost =="
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

echo "== 4/6 recovery: restarting the outpost =="
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

echo "== 5/6 outpost recreated alone, on a new address =="
# Stage 3 restarts the stand-in in place, so it keeps its address. An image
# update does not: the container is replaced and Docker hands out a new one,
# while radiusd still holds the address it resolved at startup (issue #5).
outpost_ip() {
	docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 		"$("${COMPOSE[@]}" ps -q authentik_radius)"
}
old_ip="$(outpost_ip)"
"${COMPOSE[@]}" rm -sf authentik_radius >/dev/null 2>&1
# Docker reuses the lowest free address, so the replacement would get the old
# one back and the test would prove nothing. Park a container on it first.
"${COMPOSE[@]}" run -d --rm --name akfr-e2e-squatter --entrypoint sleep client 600 >/dev/null 2>&1
"${COMPOSE[@]}" up -d --no-deps authentik_radius >/dev/null 2>&1
new_ip="$(outpost_ip)"
[ -n "$new_ip" ] && [ "$new_ip" != "$old_ip" ] || fail "the outpost kept its address ($old_ip); the recreate test cannot prove anything"
echo "   outpost moved from $old_ip to $new_ip"

deadline=$(( $(date +%s) + 90 ))
until auth; do
	if [ "$(date +%s)" -ge "$deadline" ]; then
		echo "--- freeradius log ---" >&2
		"${COMPOSE[@]}" logs --tail 20 freeradius >&2 || true
		fail "authentication did not recover within 90s after the outpost was recreated on a new address"
	fi
	sleep 5
done
docker rm -f akfr-e2e-squatter >/dev/null 2>&1 || true
echo "   ok"

echo "== 6/6 container healthcheck =="
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
