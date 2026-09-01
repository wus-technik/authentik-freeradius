#!/bin/sh
# One EAP-TTLS authentication attempt against the freeradius service.
# Exit 0 on Access-Accept, non-zero otherwise.
set -u

ip="$(getent hosts freeradius | awk '{print $1}' | head -1)"
if [ -z "$ip" ]; then
	echo "auth.sh: cannot resolve 'freeradius'" >&2
	exit 2
fi

# eapol_test -a requires an IP address, not a hostname.
eapol_test -c /ttls.conf -a "$ip" -p 1812 -s "${RADIUS_SECRET:-uplinksecret}" -r0 >/tmp/eapol.log 2>&1
rc=$?
tail -1 /tmp/eapol.log
exit "$rc"
