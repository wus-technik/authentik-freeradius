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
