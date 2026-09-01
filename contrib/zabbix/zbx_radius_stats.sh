#!/bin/sh
# Zabbix collector: FreeRADIUS Status-Server counters as a flat JSON object.
#
# Runs on the Docker host, queries the container's loopback-only statistics
# listener (sites-enabled/status, 127.0.0.1:18121) with the per-start secret
# that entrypoint.sh generates. Nothing new is exposed and no secret has to be
# configured on the monitoring side.
#
# Only FreeRADIUS-Total-* is emitted: the Stats-Elapsed-* buckets repeat once
# per section in the reply and would collide as JSON keys.
#
# Usage: zbx_radius_stats.sh [container] [port]
# Prints {} and exits 0 when radiusd does not answer, so the item keeps
# collecting and a "value too short" trigger reports the outage.
set -u

container="${1:-freeradius}"
port="${2:-18121}"

docker exec "$container" sh -c \
	"printf 'Message-Authenticator = 0x00\nFreeRADIUS-Statistics-Type = All\n' |
	 /opt/bin/radclient -x -t 2 -r 1 127.0.0.1:${port} status \"\$(cat /run/radiusd/healthcheck.secret)\"" \
	2>/dev/null \
| awk '
	/^[[:space:]]*FreeRADIUS-Total-/ {
		split($0, kv, " = ")
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
		gsub(/[^0-9]/, "", kv[2])
		if (kv[2] == "") next
		printf "%s\"%s\":%s", (n++ ? "," : "{"), kv[1], kv[2]
	}
	END { print (n ? "}" : "{}") }'
