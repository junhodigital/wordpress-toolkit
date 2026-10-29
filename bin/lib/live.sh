# Sourced by the scripts that talk to a client's LIVE site. Not run on its own.
#
# sites/<site>/live.env (written by bin/live-setup.sh) says where live is:
#   LIVE_SSH=user@host  LIVE_PORT=22  LIVE_DOCROOT=/absolute/path/to/wordpress
#   LIVE_URLS="https://example.com https://www.example.com ..."   the first is the real address
#   LIVE_EXCLUDES="wp-content/cache ..."                          never copied (caches)
# The Pi holds no key to any live host. The PC lends its key for the length of one command
# (ssh-agent forwarding, pc/pi.sh), so live is reachable only while someone runs a command
# from the PC. Host keys are pinned in secrets/ssh/known_hosts.
# (A per-client key in secrets/ssh/<site> is used instead if one exists, for unattended jobs.)

live_load() {
	site=$1
	dir=$ROOT/sites/$site
	[ -f "$dir/live.env" ] || { echo "$site is not connected to its live site: run bin/live-setup.sh" >&2; exit 2; }
	# shellcheck disable=SC1091
	. "$dir/.env"
	# shellcheck disable=SC1091
	. "$dir/live.env"
	LIVE_URL=${LIVE_URLS%% *}
	SSH_OPTS=(-p "${LIVE_PORT:-22}" -o BatchMode=yes
		-o UserKnownHostsFile="$ROOT/secrets/ssh/known_hosts" -o StrictHostKeyChecking=yes)
	if [ -f "$ROOT/secrets/ssh/$site" ]; then
		SSH_OPTS+=(-i "$ROOT/secrets/ssh/$site" -o IdentitiesOnly=yes)
	elif [ -z "${SSH_AUTH_SOCK:-}" ]; then
		echo "no access to $site's live host from here: run this from the PC with pc/pi.sh" >&2
		exit 2
	fi
}

live_ssh() { ssh "${SSH_OPTS[@]}" "$LIVE_SSH" "$@"; }

# The address the test copy answers on: its client link if it has one, else the home network.
test_url() {
	if [ -n "${PUBLIC_HOST:-}" ]; then echo "https://$PUBLIC_HOST"; else echo "http://$(hostname | tr 'A-Z' 'a-z'):$HTTP_PORT"; fi
}

# Live database, gzipped, on stdout. The password is read out of wp-config.php by PHP into a
# 0600 option file in a private temp dir outside the web root: never on a command line, in
# ps, or in this output. mysqldump directly, because shared hosts often disable proc_open,
# which `wp db export` needs. The caller checks for the "Dump completed" marker.
live_dump() {
	live_ssh "bash -s -- '$LIVE_DOCROOT'" <<'REMOTE'
set -euo pipefail
root=$1
umask 077
tmp=$(mktemp -d "$HOME/.wp-toolkit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/creds.php" <<'PHP'
<?php
$s = file_get_contents($argv[1]);
function c($s, $k) {
    return preg_match("/define\(\s*['\"]" . $k . "['\"]\s*,\s*(['\"])(.*?)\\1\s*\)/s", $s, $m) ? stripslashes($m[2]) : '';
}
$db = c($s, 'DB_NAME'); $u = c($s, 'DB_USER'); $p = c($s, 'DB_PASSWORD'); $h = c($s, 'DB_HOST') ?: 'localhost';
if ($db === '' || $u === '' || $p === '') { fwrite(STDERR, "cannot read DB settings from wp-config.php\n"); exit(1); }
$port = '';
if (strpos($h, ':') !== false) { list($h, $port) = explode(':', $h, 2); }
file_put_contents($argv[2], "[client]\nhost=\"$h\"\nuser=\"$u\"\npassword=\"" . addcslashes($p, '"\\') . "\"\n" . ($port !== '' ? "port=\"$port\"\n" : ''));
chmod($argv[2], 0600);
echo $db;
PHP
db=$(php "$tmp/creds.php" "$root/wp-config.php" "$tmp/my.cnf")
mysqldump --defaults-extra-file="$tmp/my.cnf" --single-transaction --quick --add-drop-table \
  --default-character-set=utf8mb4 "$db" | gzip
REMOTE
}

# Live files as a tar.gz on stdout, members relative to the docroot ("./wp-content/...").
# tar exits 1 when a file changes while it is read (logs, caches); that is not a failure.
live_files() {
	local ex="" e
	for e in ${LIVE_EXCLUDES:-}; do ex="$ex --exclude=./$e"; done
	live_ssh "cd '$LIVE_DOCROOT' && { tar -czf - --warning=no-file-changed $ex . ; rc=\$?; [ \$rc -le 1 ]; }"
}
