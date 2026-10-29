#!/usr/bin/env bash
# Snapshot one test site (database + files) into backups/<site>/<stamp>/.
#   bin/backup.sh vistaclinic
# Take one before any bigger change; restoring is import.sh with these two files.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
name=${1:?usage: backup.sh <site>}
dir=$ROOT/sites/$name
# shellcheck disable=SC1091
. "$dir/.env"
out=$ROOT/backups/$name/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$out"
cd "$dir"
docker compose exec -T -e MYSQL_PWD="$DB_PASSWORD" db mariadb-dump -uwordpress --single-transaction wordpress | gzip >"$out/db.sql.gz"
zcat "$out/db.sql.gz" | tail -c 200 | grep -q 'Dump completed' || { echo "dump incomplete: $out" >&2; exit 3; }
tar -czf "$out/files.tar.gz" -C "$dir" html
chmod -R go-rwx "$out"
du -sh "$out"/*
