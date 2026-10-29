#!/usr/bin/env bash
# Create a test site.
#
#   bin/new-site.sh <name> <port> [php-tag]      e.g. bin/new-site.sh acme 8082
#   PREFIX=wpkq_ bin/new-site.sh vistaclinic 8081  (table prefix, default wp_)
#
# Makes sites/<name>/ with its own docker-compose.yml, .env (random DB passwords),
# wp-config.php and the test-server guard. It does not start anything:
#   cd sites/<name> && docker compose up -d     -> http://<pi>:<port>
# For a copy of an existing site, run bin/import.sh next instead of the installer.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage="usage: new-site.sh <name> <port> [php-tag]"
name=${1:?$usage}
port=${2:?$usage}
php=${3:-php8.5}
prefix=${PREFIX:-wp_}

[[ $name =~ ^[a-z0-9-]+$ ]] || { echo "name: lowercase letters, digits and dashes only" >&2; exit 2; }
[[ $port =~ ^[0-9]+$ ]] || { echo "port must be a number" >&2; exit 2; }
dir=$ROOT/sites/$name
[ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 2; }
if grep -qsx "HTTP_PORT=$port" "$ROOT"/sites/*/.env; then
	echo "port $port is already used by: $(grep -lsx "HTTP_PORT=$port" "$ROOT"/sites/*/.env)" >&2
	exit 2
fi

rnd() { openssl rand -base64 64 | tr -d '\n/+=' | cut -c1-"${1:-32}"; }

docker network inspect wp-edge >/dev/null 2>&1 || docker network create wp-edge >/dev/null

mkdir -p "$dir/html" "$dir/db"
cp "$ROOT/template/docker-compose.yml" "$dir/"
umask 077
cat >"$dir/.env" <<EOF
SITE=$name
HTTP_PORT=$port
PHP_TAG=$php
TABLE_PREFIX=$prefix
DB_PASSWORD=$(rnd)
DB_ROOT_PASSWORD=$(rnd)
EOF
umask 022

"$ROOT/bin/write-config.sh" "$name"
echo "created $dir (port $port, $php, prefix $prefix)"
echo "next: cd $dir && docker compose up -d   or   bin/import.sh $name ..."
