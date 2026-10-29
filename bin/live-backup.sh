#!/usr/bin/env bash
# Back up a client's LIVE site onto this Pi: database and files, both verified.
#
#   bin/live-backup.sh <site> [--db-only] [--r2] [--out DIR]
#
# Writes DIR/db.sql.gz and DIR/files.tar.gz (default DIR: backups/<site>/<UTC stamp>-live/).
# A backup counts only once checked: the dump must end with mysqldump's "Dump completed"
# marker, both archives must pass gzip -t, and the files must include WordPress itself.
# --r2 then copies DIR to R2 with bin/r2-upload.sh, which downloads it back and compares.
# The last line printed is DIR.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/live.sh
. "$ROOT/bin/lib/live.sh"
usage="usage: live-backup.sh <site> [--db-only] [--r2] [--out DIR]"
site=${1:?$usage}
shift
dbonly=0 r2=0 out=""
while [ $# -gt 0 ]; do
	case $1 in
	--db-only) dbonly=1 ;;
	--r2) r2=1 ;;
	--out) out=${2:?$usage}; shift ;;
	*) echo "$usage" >&2; exit 2 ;;
	esac
	shift
done
live_load "$site"
out=${out:-$ROOT/backups/$site/$(date -u +%Y%m%dT%H%M%SZ)-live}
[ ! -e "$out/db.sql.gz" ] || { echo "$out already holds a backup" >&2; exit 2; }
umask 077
mkdir -p "$out"

echo "== live database ($LIVE_URL)" >&2
live_dump >"$out/db.sql.gz"
gzip -t "$out/db.sql.gz"
zcat "$out/db.sql.gz" | tail -c 300 | grep -q 'Dump completed' || { echo "live dump is incomplete: $out" >&2; exit 3; }

if [ $dbonly = 0 ]; then
	echo "== live files" >&2
	live_files >"$out/files.tar.gz"
	gzip -t "$out/files.tar.gz"
	tar -tzf "$out/files.tar.gz" ./wp-includes/version.php ./wp-config.php >/dev/null
fi
chmod 600 "$out"/*
du -sh "$out"/* >&2

if [ $r2 = 1 ]; then
	"$ROOT/bin/r2-upload.sh" "$site" "$(basename "$out")" "$out"/*.gz >&2
fi
echo "$out"
