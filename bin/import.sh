#!/usr/bin/env bash
# Load a copy of a live site into an EMPTY test site made by new-site.sh.
#
#   bin/import.sh <site> <files.tar.gz> <db.sql.gz> <docroot-in-tar> <new-url> <old-url>...
#
#   bin/import.sh vistaclinic backups/vistaclinic/files.tar.gz backups/vistaclinic/db.sql.gz \
#       ./domains/vistaclinic.ie/public_html http://daviderasberry:8081 \
#       https://vistaclinic.ie https://www.vistaclinic.ie http://vistaclinic.ie
#
# <docroot-in-tar> is the WordPress folder as the archive lists it (tar -tzf | head).
# Every <old-url> is rewritten to <new-url> in the database, serialized data included.
# Refuses to run over a site that already has content: delete sites/<site>/html/* and
# sites/<site>/db/* first if you really mean to start again.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage="usage: import.sh <site> <files.tar.gz> <db.sql.gz> <docroot-in-tar> <new-url> <old-url>..."
[ $# -ge 6 ] || { echo "$usage" >&2; exit 2; }
name=$1 docroot=${4%/} new=${5%/}
[ -f "$2" ] && [ -f "$3" ] || { echo "backup file missing" >&2; exit 2; }
files=$(realpath "$2") db=$(realpath "$3")
shift 5
dir=$ROOT/sites/$name
[ -f "$dir/.env" ] || { echo "no site $name; run new-site.sh first" >&2; exit 2; }
# shellcheck disable=SC1091
. "$dir/.env"

if [ -n "$(ls -A "$dir/db")" ] || [ -e "$dir/html/wp-includes" ]; then
	echo "$dir already has a site in it; refusing to import over it" >&2
	exit 2
fi

echo "== checking archives"
gzip -t "$db"
zcat "$db" | tail -c 200 | grep -q 'Dump completed' || { echo "db dump is incomplete" >&2; exit 3; }
tar -tzf "$files" "$docroot/wp-includes/version.php" >/dev/null

echo "== extracting files"
strip=$(awk -F/ '{print NF}' <<<"$docroot")
docker run --rm -v "$dir/html:/x" alpine:3 sh -c 'chown -R 1000:1000 /x'
tar -xzf "$files" -C "$dir/html" --strip-components="$strip" "$docroot"
# The copied config holds the live database password; ours replaces it below.
rm -f "$dir/html/wp-config.php"
# Host-specific cache drop-ins: they belong to the live server's caching, not to a copy.
rm -f "$dir/html/wp-content/object-cache.php" "$dir/html/wp-content/advanced-cache.php"

"$ROOT/bin/write-config.sh" "$name"

echo "== importing database"
cd "$dir"
docker compose up -d db
until [ "$(docker inspect -f '{{.State.Health.Status}}' "wp-$name-db-1")" = healthy ]; do sleep 2; done
zcat "$db" | docker compose exec -T -e MYSQL_PWD="$DB_PASSWORD" db mariadb -uwordpress wordpress

echo "== rewriting addresses to $new"
for old in "$@"; do
	"$ROOT/bin/wp.sh" "$name" search-replace "${old%/}" "$new" --all-tables-with-prefix --precise --skip-columns=guid --report-changed-only
done
"$ROOT/bin/wp.sh" "$name" option update blog_public 0
"$ROOT/bin/wp.sh" "$name" rewrite flush --hard >/dev/null 2>&1 || true

docker compose up -d
echo "== done: $new"
