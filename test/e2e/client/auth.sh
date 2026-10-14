#!/bin/sh
# One EAP authentication attempt. Exit 0 on Access-Accept, non-zero otherwise.
#   AUTH_METHOD    ttls (default) or peap
#   AUTH_USER      inner identity (default testuser / peapuser)
#   AUTH_PASSWORD  inner password (default: the one in the profile)
#   AUTH_TARGET    host to authenticate against (default freeradius)
#   AUTH_TIMEOUT   seconds before eapol_test gives up (default 30)
#   AUTH_DUMP=1    print the full eapol_test log for the caller to read
set -u

target="${AUTH_TARGET:-freeradius}"
ip="$(getent hosts "$target" | awk '{print $1}' | head -1)"
if [ -z "$ip" ]; then
	echo "auth.sh: cannot resolve '$target'" >&2
	exit 2
fi

case "${AUTH_METHOD:-ttls}" in
	ttls) profile=/ttls.conf user="${AUTH_USER:-testuser}" ;;
	peap) profile=/peap.conf user="${AUTH_USER:-peapuser}" ;;
	*)
		echo "auth.sh: unknown AUTH_METHOD '${AUTH_METHOD}'" >&2
		exit 2
		;;
esac

# wpa_supplicant takes an unquoted string value as hex, so any character --
# including the quotes and LDAP metacharacters the tests send on purpose --
# arrives verbatim, and the hex digits need no escaping in sed.
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
sed -e "s/^\([[:space:]]*\)identity=\".*\"/\1identity=$(hex "$user")/" "$profile" >/tmp/profile.conf
if [ -n "${AUTH_PASSWORD:-}" ]; then
	sed -i "s/^\([[:space:]]*\)password=\".*\"/\1password=$(hex "$AUTH_PASSWORD")/" /tmp/profile.conf
fi

# eapol_test -a requires an IP address, not a hostname.
eapol_test -c /tmp/profile.conf -a "$ip" -p 1812 -t "${AUTH_TIMEOUT:-30}" \
	-s "${RADIUS_SECRET:-e2e-uplink-secret-not-a-real-one}" -r0 >/tmp/eapol.log 2>&1
rc=$?
if [ "${AUTH_DUMP:-0}" = "1" ]; then cat /tmp/eapol.log; else tail -1 /tmp/eapol.log; fi
exit "$rc"
