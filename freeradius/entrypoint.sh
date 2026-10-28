#!/bin/sh
#
# Validates the environment, generates the healthcheck secret, optionally
# watches the TLS certificate for renewal, then hands off to radiusd.
#
# Secrets are NOT templated into configuration files. FreeRADIUS expands
# $ENV{} natively, so they stay in the process environment and never touch
# the filesystem. The previous sed-based approach corrupted any secret
# containing / & or \.
set -eu

die() {
	echo "entrypoint: $*" >&2
	exit 1
}

for var in RADIUS_SECRET AUTHENTIK_RADIUS_SECRET RADIUS_CLIENT_NET AUTHENTIK_RADIUS_HOST; do
	eval "value=\${$var:-}"
	[ -n "$value" ] || die "required environment variable $var is unset or empty"
done

case "$RADIUS_CLIENT_NET" in
	0.0.0.0/0|::/0)
		die "RADIUS_CLIENT_NET must not be $RADIUS_CLIENT_NET - scope it to the AP/controller subnet"
		;;
esac

for var in RADIUS_SECRET AUTHENTIK_RADIUS_SECRET; do
	eval "value=\${$var}"
	case "$value" in
		CHANGEME*)
			die "$var still holds the placeholder from .env.example - generate one with: openssl rand -hex 32"
			;;
	esac
	if [ "${#value}" -lt 16 ]; then
		die "$var must be at least 16 characters (got ${#value})"
	fi
done

CERT_FILE="${TLS_CERT_PATH:-/etc/raddb/certs/server.crt}"
KEY_FILE="${TLS_KEY_PATH:-/etc/raddb/certs/server.key}"
export TLS_CERT_PATH="$CERT_FILE"
export TLS_KEY_PATH="$KEY_FILE"

[ -r "$CERT_FILE" ] || die "certificate '$CERT_FILE' is missing or unreadable (check the volume mount)"
[ -r "$KEY_FILE" ] || die "private key '$KEY_FILE' is missing or unreadable (check the volume mount)"

# Loopback-only secret for the container healthcheck. Regenerated every start;
# no default exists anywhere in the repository.
mkdir -p /run/radiusd
RADIUS_HEALTHCHECK_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export RADIUS_HEALTHCHECK_SECRET
( umask 077; printf '%s' "$RADIUS_HEALTHCHECK_SECRET" > /run/radiusd/healthcheck.secret )

# VLAN_MAP="name=vlan-id ..." becomes a switch on the Filter-Id that an
# authentik property mapping returns. Both halves are validated before they go
# anywhere near unlang, so the generated file cannot carry anything else. An
# unmapped name adds nothing: the client lands in the SSID's own VLAN.
write_vlan_map() {
	out=/run/radiusd/vlan-map.conf
	map="$(printf '%s' "${VLAN_MAP:-}" | tr ',' ' ')"
	if [ -z "$(printf '%s' "$map" | tr -d ' \t\n')" ]; then
		: > "$out"
		return 0
	fi
	body=""
	for pair in $map; do
		name="${pair%%=*}"
		vlan="${pair#*=}"
		printf '%s\n' "$name" | grep -qxE '[A-Za-z0-9._-]{1,64}' \
			|| die "VLAN_MAP: '$pair' - the name must be 1-64 of A-Z a-z 0-9 . _ -"
		case "$vlan" in
			''|*[!0-9]*) die "VLAN_MAP: '$pair' - expected name=vlan-id" ;;
		esac
		if [ "$vlan" -lt 1 ] || [ "$vlan" -gt 4094 ]; then
			die "VLAN_MAP: '$pair' - the VLAN id must be 1-4094"
		fi
		body="$body$(printf '	case "%s" {
		update reply {
			&Tunnel-Type := VLAN
			&Tunnel-Medium-Type := IEEE-802
			&Tunnel-Private-Group-Id := "%s"
		}
	}' "$name" "$vlan")
"
	done
	printf 'if (&reply:Filter-Id) {
	switch &reply:Filter-Id {
%s	}
}
' "$body" > "$out"
	echo "entrypoint: dynamic VLAN enabled for $(grep -c 'case ' "$out") Filter-Id name(s)" >&2
}
write_vlan_map

# Hash the resolved content rather than stat the path: certbot repoints the
# live/ symlinks at new archive/ files, so mtime on the old inode never moves.
cert_fingerprint() {
	cat "$CERT_FILE" "$KEY_FILE" 2>/dev/null | md5sum | cut -d' ' -f1
}

watch_certificates() {
	target_pid="$1"
	baseline="$(cert_fingerprint)"
	while sleep "${CERT_RELOAD_INTERVAL:-3600}"; do
		if [ "$(cert_fingerprint)" != "$baseline" ]; then
			echo "entrypoint: certificate changed, restarting radiusd" >&2
			kill -TERM "$target_pid" 2>/dev/null || true
			return 0
		fi
	done
}

# The outpost has a fixed address on the radius network (issue #15). A name is
# refused: once its container is stopped, Docker forwards the name to the
# host's resolver, which may answer with an address that is not ours -- and
# radiusd would then proxy inner PAP requests to it.
is_ipv4() {
	case "$1" in
		*'
'*) return 1 ;;
	esac
	octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
	printf '%s\n' "$1" | grep -qxE "($octet\.){3}$octet"
}

is_ipv4 "$AUTHENTIK_RADIUS_HOST" \
	|| die "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address (got '$AUTHENTIK_RADIUS_HOST') - give the outpost a fixed address, see docker-compose.yml"

if [ -n "${OUTPOST_RESOLVE_INTERVAL:-}" ]; then
	echo "entrypoint: OUTPOST_RESOLVE_INTERVAL has no effect any more - the outpost has a fixed address" >&2
fi

# PEAP_ENABLE=true adds PEAP-MSCHAPv2 against the authentik LDAP outpost
# (issue #14). The modules live in /etc/raddb/peap/, outside mods-enabled/,
# so with PEAP off ldap is never instantiated; these includes are the switch.
write_peap_includes() {
	modules=/run/radiusd/peap-modules.conf
	eap=/run/radiusd/peap-eap.conf
	site=/run/radiusd/peap-site.conf
	case "${PEAP_ENABLE:-false}" in
		false)
			: > "$modules"
			: > "$eap"
			: > "$site"
			return 0
			;;
		true) ;;
		*) die "PEAP_ENABLE must be true or false (got '${PEAP_ENABLE}')" ;;
	esac

	for var in LDAP_HOST LDAP_BASE_DN LDAP_BIND_DN LDAP_BIND_PASSWORD LDAP_WLAN_GROUP_DN; do
		eval "value=\${$var:-}"
		[ -n "$value" ] || die "PEAP_ENABLE=true requires $var"
	done
	# shellcheck disable=SC2153 # LDAP_HOST is checked by the loop above
	is_ipv4 "$LDAP_HOST" \
		|| die "LDAP_HOST must be a literal IPv4 address (got '$LDAP_HOST') - give the LDAP outpost a fixed address"

	# The DNs go into the configuration and the LDAP filter at parse time,
	# before rlm_ldap escapes anything, so only harmless characters pass.
	for var in LDAP_BASE_DN LDAP_BIND_DN LDAP_WLAN_GROUP_DN; do
		eval "value=\${$var}"
		case "$value" in
			*'
'*) die "$var must be a single line" ;;
		esac
		printf '%s\n' "$value" | grep -qxE '[A-Za-z0-9=,._ -]{1,255}' \
			|| die "$var may only contain A-Z a-z 0-9 = , . _ - and spaces (got '$value')"
	done

	LDAP_PORT="${LDAP_PORT:-3389}"
	case "$LDAP_PORT" in
		''|*[!0-9]*) die "LDAP_PORT must be a port number (got '$LDAP_PORT')" ;;
	esac
	# No leading zero (that also rules out 0); the length check keeps test(1)
	# away from numbers too large for it.
	case "$LDAP_PORT" in
		0*) die "LDAP_PORT must be 1-65535 (got '$LDAP_PORT')" ;;
	esac
	{ [ "${#LDAP_PORT}" -le 5 ] && [ "$LDAP_PORT" -le 65535 ]; } \
		|| die "LDAP_PORT must be 1-65535 (got '$LDAP_PORT')"
	export LDAP_PORT

	# shellcheck disable=SC2016 # literal FreeRADIUS directive
	printf '$INCLUDE /etc/raddb/peap/ldap\n$INCLUDE /etc/raddb/peap/inner-eap\n$INCLUDE /etc/raddb/peap/linelog\n' > "$modules"
	# shellcheck disable=SC2016 # literal FreeRADIUS directive
	printf '$INCLUDE /etc/raddb/peap/eap-peap\n' > "$eap"
	# shellcheck disable=SC2016 # literal FreeRADIUS directive
	printf '$INCLUDE /etc/raddb/peap/peap-inner-tunnel\n' > "$site"
	echo "entrypoint: PEAP-MSCHAPv2 enabled, LDAP outpost at $LDAP_HOST:$LDAP_PORT" >&2
}
write_peap_includes

# USERNAME_STRIP_DOMAIN=true accepts "user@any.domain" as "user",
# USERNAME_STRIP_NTDOMAIN=true "ANYDOMAIN\user" (issue #8).
# policy.d/username_domain reads both through $ENV{}; only the two literal
# values may reach that comparison.
USERNAME_STRIP_DOMAIN="${USERNAME_STRIP_DOMAIN:-false}"
USERNAME_STRIP_NTDOMAIN="${USERNAME_STRIP_NTDOMAIN:-false}"
for var in USERNAME_STRIP_DOMAIN USERNAME_STRIP_NTDOMAIN; do
	eval "value=\${$var}"
	case "$value" in
		true|false) ;;
		*) die "$var must be true or false (got '$value')" ;;
	esac
done
[ "$USERNAME_STRIP_DOMAIN" = false ] \
	|| echo "entrypoint: usernames of the form user@domain are looked up as user" >&2
[ "$USERNAME_STRIP_NTDOMAIN" = false ] \
	|| echo "entrypoint: usernames of the form DOMAIN\user are looked up as user" >&2
export USERNAME_STRIP_DOMAIN USERNAME_STRIP_NTDOMAIN

if [ "${CERT_RELOAD_WATCH:-false}" = "true" ]; then
	case "${CERT_RELOAD_INTERVAL:-3600}" in
		''|*[!0-9]*)
			die "CERT_RELOAD_INTERVAL must be a positive integer number of seconds (got '${CERT_RELOAD_INTERVAL}')"
			;;
	esac
	echo "entrypoint: certificate watcher armed (interval ${CERT_RELOAD_INTERVAL:-3600}s)" >&2
	# $$ is this shell, which exec below turns into the radiusd process.
	watch_certificates "$$" &
fi

# -f keeps radiusd in the foreground; without it the container exits
# immediately. -l stdout keeps logging off the read-only filesystem.
set -- -f -l stdout -d /etc/raddb "$@"

if [ "${FREERADIUS_ENABLE_DEBUG:-false}" = "true" ]; then
	echo "entrypoint: WARNING debug mode logs inner-tunnel cleartext passwords" >&2
	set -- -X "$@"
fi

exec /opt/sbin/radiusd "$@"
