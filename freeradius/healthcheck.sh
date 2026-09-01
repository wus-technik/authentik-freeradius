#!/bin/sh
# Container healthcheck: prove radiusd is listening and processing packets,
# not merely that the process exists.
#
# radclient's exit status is the signal and MUST NOT be piped -- through tail
# or grep the shell reports the pipeline's status, which is always 0, giving a
# healthcheck that can never fail.
set -eu

secret_file=/run/radiusd/healthcheck.secret
[ -r "$secret_file" ] || exit 1

printf 'Message-Authenticator = 0x00\n' \
	| /opt/bin/radclient -q -t 2 -r 1 127.0.0.1:1812 status "$(cat "$secret_file")" \
	>/dev/null 2>&1
