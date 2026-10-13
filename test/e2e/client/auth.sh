#!/bin/sh
# One EAP-TTLS authentication attempt against the freeradius service.
# Exit 0 on Access-Accept, non-zero otherwise. AUTH_USER picks the inner
# identity; AUTH_DUMP=1 prints the full eapol_test log for the caller to read.
set -u

ip="$(getent hosts freeradius | awk '{print $1}' | head -1)"
if [ -z "$ip" ]; then
	echo "auth.sh: cannot resolve 'freeradius'" >&2
	exit 2
fi

# eapol_test -a requires an IP address, not a hostname.
sed "s/identity=\"testuser\"/identity=\"${AUTH_USER:-testuser}\"/" /ttls.conf >/tmp/ttls.conf
eapol_test -c /tmp/ttls.conf -a "$ip" -p 1812 -s "${RADIUS_SECRET:-e2e-uplink-secret-not-a-real-one}" -r0 >/tmp/eapol.log 2>&1
rc=$?
if [ "${AUTH_DUMP:-0}" = "1" ]; then cat /tmp/eapol.log; else tail -1 /tmp/eapol.log; fi
exit "$rc"
