#!/usr/bin/env bash
# Move a test site to a new address, e.g. from the home-network port to its tunnel name.
#   bin/set-url.sh vistaclinic https://vistaclinic.example.com
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
name=${1:?usage: set-url.sh <site> <new-url>}
new=${2%/}
old=$("$ROOT/bin/wp.sh" "$name" option get home | tr -d '\r')
[ "$old" != "$new" ] || { echo "already $new"; exit 0; }
echo "$old -> $new"
"$ROOT/bin/wp.sh" "$name" search-replace "$old" "$new" --all-tables-with-prefix --precise --skip-columns=guid --report-changed-only
"$ROOT/bin/wp.sh" "$name" cache flush >/dev/null 2>&1 || true
