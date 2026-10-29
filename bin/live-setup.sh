#!/usr/bin/env bash
# Connect a test site to its live site. Once per client.
#
#   bin/live-setup.sh <site> <user@host> <port> <docroot> <live-url> [other urls of the site...]
#
#   bin/live-setup.sh vistaclinic u305482107@195.35.31.84 65002 \
#       /home/u305482107/domains/vistaclinic.ie/public_html \
#       https://vistaclinic.ie https://www.vistaclinic.ie http://vistaclinic.ie http://www.vistaclinic.ie
#
#   pc/pi.sh bin/live-setup.sh <site> --test      check the connection (from the PC)
#
# Writes sites/<site>/live.env and pins the host's key (first use; compare it with the PC's
# known_hosts). The Pi gets no key: the PC lends its own for each command through pc/pi.sh,
# so the PC needs SSH access to the host first. Every URL listed is rewritten to the test
# address on refresh, and back on publish.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/live.sh
. "$ROOT/bin/lib/live.sh"
usage="usage: live-setup.sh <site> <user@host> <port> <docroot> <live-url> [urls...]  |  <site> --test"
site=${1:?$usage}
[ -f "$ROOT/sites/$site/.env" ] || { echo "no site $site" >&2; exit 2; }

if [ "${2:-}" != --test ]; then
	[ $# -ge 5 ] || { echo "$usage" >&2; exit 2; }
	target=$2 port=$3 docroot=${4%/}
	shift 4
	[[ $docroot == /* ]] || { echo "docroot must be an absolute path" >&2; exit 2; }
	cat >"$ROOT/sites/$site/live.env" <<EOF
LIVE_SSH=$target
LIVE_PORT=$port
LIVE_DOCROOT=$docroot
LIVE_URLS="$*"
LIVE_EXCLUDES="wp-content/cache wp-content/litespeed wp-content/upgrade wp-content/ai1wm-backups wp-content/updraft"
EOF
	mkdir -p "$ROOT/secrets/ssh"
	chmod 700 "$ROOT/secrets/ssh"
	host=${target#*@}
	if ! ssh-keygen -F "[$host]:$port" -f "$ROOT/secrets/ssh/known_hosts" >/dev/null 2>&1; then
		ssh-keyscan -p "$port" "$host" 2>/dev/null >>"$ROOT/secrets/ssh/known_hosts"
	fi
	echo "host key pinned:"
	ssh-keygen -lF "[$host]:$port" -f "$ROOT/secrets/ssh/known_hosts" | grep -v '^#'
	echo "next, from the PC: pc/pi.sh bin/live-setup.sh $site --test"
	exit 0
fi

live_load "$site"
live_ssh "test -f '$LIVE_DOCROOT/wp-config.php'" || { echo "connected, but no wp-config.php in $LIVE_DOCROOT" >&2; exit 3; }
prefix=$(live_ssh "php -- '$LIVE_DOCROOT/wp-config.php'" <<'PHP'
<?php
preg_match('/table_prefix\s*=\s*[\'"]([^\'"]+)/', file_get_contents($argv[1]), $m);
echo $m[1] ?? '';
PHP
)
home=$(live_ssh "cd '$LIVE_DOCROOT' && wp option get home" 2>/dev/null || true)
echo "connected: $LIVE_SSH, $LIVE_DOCROOT"
echo "live home: ${home:-<wp-cli unavailable>}   table prefix: $prefix (test copy: $TABLE_PREFIX)"
[ "$prefix" = "$TABLE_PREFIX" ] || { echo "table prefix differs: recreate the test site with PREFIX=$prefix" >&2; exit 3; }
[ -z "$home" ] || [ "${home%/}" = "$LIVE_URL" ] || echo "warning: live home is $home but the first LIVE_URLS entry is $LIVE_URL" >&2
