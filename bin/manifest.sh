#!/usr/bin/env bash
# Record what live looked like at refresh time, so bin/publish.py can refuse to overwrite
# anything changed on live since. Called by refresh.sh through import.sh, right after the
# live database is loaded and BEFORE its addresses are rewritten, so every value here is
# live's own.
#
#   sites/<site>/manifest/posts.tsv     ID, post_modified_gmt
#   sites/<site>/manifest/options.tsv   option_name, MD5(option_value)
#   sites/<site>/manifest/files.md5     md5sum of every file under wp-content
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
name=${1:?usage: manifest.sh <site>}
dir=$ROOT/sites/$name
# shellcheck disable=SC1091
. "$dir/.env"
new=$dir/manifest.new
rm -rf "$new"
mkdir -p "$new"

echo "== recording live state (manifest)"
"$ROOT/bin/wp.sh" "$name" db query "SELECT ID, post_modified_gmt FROM ${TABLE_PREFIX}posts" --skip-column-names >"$new/posts.tsv"
"$ROOT/bin/wp.sh" "$name" db query "SELECT option_name, MD5(option_value) FROM ${TABLE_PREFIX}options" --skip-column-names >"$new/options.tsv"
(cd "$dir/html" && find wp-content -type f -print0 | xargs -0 md5sum) >"$new/files.md5"
date -u +%Y-%m-%dT%H:%M:%SZ >"$new/made"
[ -s "$new/posts.tsv" ] && [ -s "$new/files.md5" ] || { echo "manifest came out empty" >&2; exit 3; }
rm -rf "$dir/manifest"
mv "$new" "$dir/manifest"
wc -l "$dir/manifest"/*.tsv "$dir/manifest/files.md5" | sed 's/^/   /'
