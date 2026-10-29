#!/usr/bin/env bash
# Run WP-CLI against one test site.
#   bin/wp.sh vistaclinic plugin list
#   bin/wp.sh vistaclinic option get home
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
name=${1:?usage: wp.sh <site> <wp-cli args...>}
shift
cd "$ROOT/sites/$name"
exec docker compose run --rm -T cli wp "$@"
