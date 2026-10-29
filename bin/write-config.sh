#!/usr/bin/env bash
# (Re)write sites/<name>/html/wp-config.php for a test copy, install the test-server guard
# and fix file ownership. Called by new-site.sh and import.sh.
#
# The config is always ours, never the client's: a copied wp-config.php carries the live
# database password and live cookie keys. Fresh salts here mean a live login cookie is
# worthless on the copy and the other way round.
#
# Site-specific constants go in sites/<name>/wp-config-extra.php (plain PHP lines, no <?php);
# they are pasted in above the "stop editing" point every time this runs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
name=${1:?usage: write-config.sh <name>}
dir=$ROOT/sites/$name
# shellcheck disable=SC1091
. "$dir/.env"

salt() { openssl rand -base64 64 | tr -d '\n/+=' | cut -c1-64; }
extra=""
[ -f "$dir/wp-config-extra.php" ] && extra=$(cat "$dir/wp-config-extra.php")

cfg=$dir/html/wp-config.php
cat >"$cfg.tmp" <<EOF
<?php
// TEST COPY of site "$SITE", written by wordpressServers/bin/write-config.sh.
// Not the live site's config. Regenerated on import; put lasting changes in
// sites/$SITE/wp-config-extra.php, not here.

define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wordpress' );
define( 'DB_PASSWORD', '$DB_PASSWORD' );
define( 'DB_HOST', 'db' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

define( 'AUTH_KEY',         '$(salt)' );
define( 'SECURE_AUTH_KEY',  '$(salt)' );
define( 'LOGGED_IN_KEY',    '$(salt)' );
define( 'NONCE_KEY',        '$(salt)' );
define( 'AUTH_SALT',        '$(salt)' );
define( 'SECURE_AUTH_SALT', '$(salt)' );
define( 'LOGGED_IN_SALT',   '$(salt)' );
define( 'NONCE_SALT',       '$(salt)' );

\$table_prefix = '$TABLE_PREFIX';

define( 'WP_ENVIRONMENT_TYPE', 'staging' );
define( 'DISABLE_WP_CRON', true );            // no scheduled jobs reaching out from a copy
define( 'AUTOMATIC_UPDATER_DISABLED', true ); // stay on the versions the live site runs
define( 'DISALLOW_FILE_EDIT', true );
define( 'FS_METHOD', 'direct' );
define( 'WP_DEBUG', false );

// Cloudflare Tunnel delivers https visits as plain http; trust its forwarded scheme.
if ( isset( \$_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === \$_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
	\$_SERVER['HTTPS'] = 'on';
}

$extra

/* That's all, stop editing! */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOF
mv "$cfg.tmp" "$cfg"

mkdir -p "$dir/html/wp-content/mu-plugins"
cp "$ROOT/template/test-server-guard.php" "$dir/html/wp-content/mu-plugins/zz-test-server-guard.php"

# Apache runs as uid 33; group 1000 (dnasc) keeps the files editable from the Pi's shell.
docker run --rm -v "$dir/html:/x" alpine:3 sh -c 'chown -R 33:1000 /x && chmod -R g+rwX /x && chmod 640 /x/wp-config.php'
