#!/usr/bin/env bash
# Integration test against a real authentik (spec 8.3): blueprint import, the
# WiFi password flow, the real LDAP outpost and PEAP through FreeRADIUS.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.yml)

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf .state; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; "${COMPOSE[@]}" logs --tail 30 freeradius authentik_ldap >&2 || true; exit 1; }
peap() {
	"${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_METHOD=peap -e AUTH_USER="$1" \
		-e AUTH_PASSWORD="$2" client >/dev/null 2>&1
}
notfound() {
	"${COMPOSE[@]}" logs freeradius 2>&1 | grep -c "peap: no active WLAN user with a WiFi password: $1\$" || true
}
# rejected directory|password <user> <password> <what>: PEAP must end in an
# Access-Reject, not in a failing client or container, and for the stated
# reason. directory: the LDAP filter found no active WLAN user (its log line).
# password: the user was found and MSCHAPv2 refused the password.
rejected() {
	local before after out rc=0
	before="$(notfound "$2")"
	out="$("${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_METHOD=peap -e AUTH_USER="$2" \
		-e AUTH_PASSWORD="$3" -e AUTH_DUMP=1 client 2>&1)" || rc=$?
	[ "$rc" -ne 0 ] || fail "PEAP accepted $4"
	printf '%s\n' "$out" | grep -q 'code=3 (Access-Reject)' \
		|| fail "PEAP with $4 failed without an Access-Reject: $(printf '%s\n' "$out" | tail -3)"
	after="$(notfound "$2")"
	case "$1" in
		directory) [ "$after" -gt "$before" ] || fail "PEAP refused $4, but not in the directory lookup" ;;
		password) [ "$after" -eq "$before" ] || fail "PEAP refused $4 in the directory lookup, not on the password" ;;
	esac
}

mkdir -p .state
echo "== building and starting authentik =="
"${COMPOSE[@]}" build --quiet
"${COMPOSE[@]}" run --rm certgen >/dev/null
"${COMPOSE[@]}" up -d postgresql server worker
deadline=$(( $(date +%s) + 300 ))
#  A shell redirect, not -o /dev/null: with MSYS_NO_PATHCONV=1 the Windows curl
#  of Git Bash gets the literal path, cannot write it and fails with exit 23.
until curl -sf http://127.0.0.1:19000/-/health/ready/ >/dev/null; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "authentik did not become ready"
	sleep 5
done
echo "== blueprint, users, service account, outpost =="
python3 -I drive.py setup
set -a
# shellcheck disable=SC1091 # written by drive.py setup
. .state/it.env
set +a
"${COMPOSE[@]}" up -d authentik_ldap freeradius
deadline=$(( $(date +%s) + 120 ))
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$("${COMPOSE[@]}" ps -q authentik_ldap)")" = healthy ]; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "LDAP outpost did not become healthy"
	sleep 3
done

echo "== WiFi password flow =="
python3 -I drive.py flow peapuser it-user-pw-0123456789 .state/pw1
python3 -I drive.py denied outsider it-user-pw-0123456789 || fail "a user outside the WLAN group got the flow"

echo "== PEAP with the generated password =="
pw1="$(cat .state/pw1)"
deadline=$(( $(date +%s) + 60 ))
until peap peapuser "$pw1"; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "PEAP with the generated password was rejected"
	sleep 3
done
rejected password peapuser wrong-password "a wrong password"
rejected password peapuser it-user-pw-0123456789 "the SSO password"

echo "== deactivation applies at once =="
python3 -I drive.py active peapuser 0
rejected directory peapuser "$pw1" "a deactivated user"
python3 -I drive.py active peapuser 1
peap peapuser "$pw1" || fail "PEAP refused the reactivated user"

echo "== a new password replaces the old one =="
python3 -I drive.py flow peapuser it-user-pw-0123456789 .state/pw2
pw2="$(cat .state/pw2)"
[ "$pw1" != "$pw2" ] || fail "the flow showed the same passphrase again after saving"
rejected password peapuser "$pw1" "the old WiFi password"
peap peapuser "$pw2" || fail "the new WiFi password does not work"

echo "== the hash stays out of the event log, users cannot bind =="
hash="$(python3 -I -c 'import sys; ns={}; exec(open("../../authentik/src/md4.py").read(), ns); print(ns["md4"](sys.argv[1].encode("utf-16-le")).hex().upper())' "$pw2")"
python3 -I drive.py nohash "$hash" || fail "the NT hash appears in the event log"
ldap_search() {
	"${COMPOSE[@]}" run --rm --quiet-pull --entrypoint ldapsearch client -x -H ldap://172.29.0.11:3389 \
		-D "cn=$1,ou=users,dc=ldap,dc=goauthentik,dc=io" -w "$2" \
		-b dc=ldap,dc=goauthentik,dc=io '(cn=*)' cn 2>&1
}
# Positive control: the same search works for the service account, so the
# refusal below is about the user and not about the command.
ldap_search svc-wlan-ldap "$IT_LDAP_BIND_PASSWORD" >/dev/null \
	|| fail "the service account cannot search; the bind check would prove nothing"
rc=0
out="$(ldap_search peapuser it-user-pw-0123456789)" || rc=$?
[ "$rc" -ne 0 ] || fail "an ordinary user could bind to the wlan-ldap provider"
printf '%s\n' "$out" | grep -q 'Insufficient access (50)' \
	|| fail "the bind of an ordinary user failed, but not with Insufficient access: $out"

echo
echo "PASS: authentik integration checks succeeded"
