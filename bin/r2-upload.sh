#!/usr/bin/env bash
# Copy backup files to Cloudflare R2 and prove they arrived intact.
#
#   bin/r2-upload.sh <site> <label> <file>...
#   bin/r2-upload.sh vistaclinic 2026-10-27-live backups/vistaclinic/live-20261027-*.gz
#
# Files land at <bucket>/<site>/<label>/<file name>, next to a SHA256SUMS of the originals.
# Every file is downloaded again and its MD5 compared with the local one, so "uploaded"
# means the bytes in R2 are the bytes on this disk. A label that already has files in R2
# is refused: a backup is never overwritten. Key, endpoint and bucket: secrets/r2.env.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 3 ] || { echo "usage: r2-upload.sh <site> <label> <file>..." >&2; exit 2; }
site=$1 label=$2
shift 2
case "$site$label" in */* | *..*) echo "site and label must not contain / or .." >&2; exit 2 ;; esac
set -a
# shellcheck disable=SC1091
. "$ROOT/secrets/r2.env"
set +a

# rclone runs in a container; its key goes in through an env file, never the command line.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(
	umask 077
	printf '%s\n' RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
		"RCLONE_CONFIG_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID" \
		"RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY" \
		"RCLONE_CONFIG_R2_ENDPOINT=$R2_ENDPOINT" RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true >"$tmp/rclone.env"
)
r2() { # r2 <host dir, mounted read-only at /data> <rclone args>...
	local dir=$1
	shift
	docker run --rm --env-file "$tmp/rclone.env" -v "$dir:/data:ro" rclone/rclone:1.68.2 "$@"
}
dest=r2:$R2_BUCKET/$site/$label

echo "== checking local files"
for f in "$@"; do
	[ -f "$f" ] || { echo "not a file: $f" >&2; exit 2; }
	case $f in *.gz) gzip -t "$f" ;; esac
done
if [ -n "$(r2 "$tmp" lsf "$dest" 2>/dev/null)" ]; then
	echo "$dest already has files; refusing to overwrite a backup" >&2
	exit 2
fi
for f in "$@"; do (cd "$(dirname "$f")" && sha256sum "$(basename "$f")"); done >"$tmp/SHA256SUMS"

for f in "$@"; do
	b=$(basename "$f") d=$(cd "$(dirname "$f")" && pwd)
	echo "== uploading $b ($(du -h "$f" | cut -f1))"
	r2 "$d" copyto "/data/$b" "$dest/$b"
	echo "   verifying: downloading it back"
	remote=$(r2 "$tmp" md5sum --download "$dest/$b" | cut -d' ' -f1)
	local_md5=$(md5sum "$f" | cut -d' ' -f1)
	[ "$remote" = "$local_md5" ] || { echo "MISMATCH on $b: local $local_md5, R2 $remote" >&2; exit 3; }
	echo "   OK md5 $local_md5"
done
r2 "$tmp" copyto /data/SHA256SUMS "$dest/SHA256SUMS"

echo "== in R2 now: $R2_BUCKET/$site/$label/"
r2 "$tmp" lsl "$dest"
