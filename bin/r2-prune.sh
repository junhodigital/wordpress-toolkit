#!/usr/bin/env bash
# Keep only the newest backups of one client in R2; delete the older ones.
#
#   bin/r2-prune.sh <site> [--keep N] [--protect LABEL] [--yes]
#
# Each folder <bucket>/<site>/<label>/ is one backup. Folders are ranked by the newest file
# inside them (upload time, not the label's spelling, since labels have used two date formats).
# The newest N (default 2: the previous backup and the current one) are kept, the rest deleted.
# Without --yes it only prints the plan. --protect LABEL is never deleted, whatever its rank;
# bin/r2-upload.sh passes the label it has just uploaded and verified.
# Files sitting directly in <site>/, outside any folder, are left alone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage="usage: r2-prune.sh <site> [--keep N] [--protect LABEL] [--yes]"
site=${1:?$usage}
shift
keep=2 protect="" yes=0
while [ $# -gt 0 ]; do
	case $1 in
	--keep) keep=${2:?$usage}; shift ;;
	--protect) protect=${2:?$usage}; shift ;;
	--yes) yes=1 ;;
	*) echo "$usage" >&2; exit 2 ;;
	esac
	shift
done
case "$site" in "" | */* | *..*) echo "site must not be empty or contain / or .." >&2; exit 2 ;; esac
case "$keep" in '' | *[!0-9]*) echo "--keep must be a number" >&2; exit 2 ;; esac
[ "$keep" -ge 2 ] || { echo "--keep must be at least 2" >&2; exit 2; }
set -a
# shellcheck disable=SC1091
. "$ROOT/secrets/r2.env"
set +a

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(
	umask 077
	printf '%s\n' RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
		"RCLONE_CONFIG_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID" \
		"RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY" \
		"RCLONE_CONFIG_R2_ENDPOINT=$R2_ENDPOINT" RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true >"$tmp/rclone.env"
)
r2() { docker run --rm --env-file "$tmp/rclone.env" rclone/rclone:1.68.2 "$@"; }
base=r2:$R2_BUCKET/$site

# "<mod time>;<label>/<file>" for every file, then the newest time per label, newest first.
r2 lsf -R --files-only --format tp "$base" >"$tmp/files"
awk -F';' 'index($2, "/") { l = substr($2, 1, index($2, "/") - 1); if ($1 > t[l]) t[l] = $1 }
	END { for (l in t) print t[l] ";" l }' "$tmp/files" | sort -r >"$tmp/ranked"

n=$(wc -l <"$tmp/ranked")
echo "== $R2_BUCKET/$site/: $n backup(s), keeping the newest $keep"
i=0 doomed=()
while IFS=';' read -r t label; do
	i=$((i + 1))
	if [ "$i" -le "$keep" ] || [ "$label" = "$protect" ]; then
		echo "   keep    $label  ($t)"
	else
		echo "   delete  $label  ($t)"
		doomed+=("$label")
	fi
done <"$tmp/ranked"

if [ -n "$protect" ] && ! grep -q ";$protect\$" "$tmp/ranked"; then
	echo "protected backup $protect is not in R2; deleting nothing" >&2
	exit 3
fi
[ ${#doomed[@]} -gt 0 ] || { echo "== nothing to delete"; exit 0; }
[ $yes = 1 ] || { echo "== plan only; add --yes to delete"; exit 0; }
for label in "${doomed[@]}"; do
	case "$label" in "" | */* | *..*) echo "refusing odd label: $label" >&2; exit 3 ;; esac
	r2 purge "$base/$label"
	echo "   deleted $label"
done
