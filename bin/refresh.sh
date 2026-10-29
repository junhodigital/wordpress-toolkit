#!/usr/bin/env bash
# Replace a test site with a fresh copy of its live site (WORKFLOW.md, step B1).
#
#   bin/refresh.sh <site>          say what would happen, change nothing
#   bin/refresh.sh <site> --yes    do it
#
#   1. back up live (database + files), verified, to backups/<site>/<stamp>-live/ and R2
#   2. snapshot the test copy as it is now, so work not yet published is never lost
#   3. empty the test copy and import the live backup into it (bin/import.sh)
#   4. record live's state in sites/<site>/manifest/ (bin/manifest.sh), which publish.py
#      uses to refuse overwriting anything changed on live after this moment
#   5. run sites/<site>/after-import.sh if the site has one: its own test-copy-only changes
#      (plugins to switch off, files to remove), kept on the Pi next to NOTES.md
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/live.sh
. "$ROOT/bin/lib/live.sh"
site=${1:?usage: refresh.sh <site> [--yes]}
live_load "$site"
new=$(test_url)

if [ "${2:-}" != --yes ]; then
	cat <<EOF
refresh $site: $LIVE_URL  ->  $new

  1. back up live (database + files) to backups/$site/ and R2
  2. snapshot the test copy as it is now (bin/backup.sh), so nothing is lost
  3. REPLACE the test copy with live; anything done on it since the last refresh is gone
     from the site (it stays in the snapshot)
  4. record live's state for publish.py
  5. $([ -x "$dir/after-import.sh" ] && echo "run sites/$site/after-import.sh" || echo "(no after-import.sh for this site)")

Nothing changed. Run again with --yes.
EOF
	exit 0
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
lb=$("$ROOT/bin/live-backup.sh" "$site" --r2 --out "$ROOT/backups/$site/$stamp-live")

echo "== snapshot of the test copy before replacing it"
"$ROOT/bin/backup.sh" "$site"

echo "== emptying the test copy"
(cd "$dir" && docker compose down)
docker run --rm -v "$dir/html:/h" -v "$dir/db:/d" alpine:3 \
	sh -c 'find /h /d -mindepth 1 -maxdepth 1 -exec rm -rf {} +'

# shellcheck disable=SC2086 # LIVE_URLS is a list
AFTER_DB_IMPORT="$ROOT/bin/manifest.sh" "$ROOT/bin/import.sh" "$site" "$lb/files.tar.gz" "$lb/db.sql.gz" . "$new" $LIVE_URLS

if [ -x "$dir/after-import.sh" ]; then
	echo "== sites/$site/after-import.sh"
	"$dir/after-import.sh"
fi
echo "== refreshed: $new is now live as of $stamp"
