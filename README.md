# wordpress-toolkit

Shared tools for every client WordPress site. Test copies run on the Raspberry Pi (Docker),
checked out at `~/Documents/wordpressServers`: one folder per client under `sites/`, each with
its own WordPress and its own database. Backups go to Cloudflare R2. Clients review a site
through a Cloudflare Tunnel; nothing here is ever the live site.

**`WORKFLOW.md` is the step-by-step for every client. `CLAUDE.md` holds the rules.**

## Layout

| Path | What | In git |
|---|---|---|
| `template/` | Shared Docker setup, PHP settings and the test-server guard, copied or mounted into every site | yes |
| `bin/` | The scripts below | yes |
| `sites/<name>/` | One client: `docker-compose.yml`, `.env` (port, PHP version, DB passwords), `html/` (WordPress), `db/` (database files), notes | **no** |
| `backups/<name>/` | Snapshots from `bin/backup.sh` and copies of live backups. Never published | **no** |
| `secrets/` | `r2.env`: R2 key, `.eu.` endpoint, bucket. Mode 600 | **no** |
| `edge/` | The Cloudflare Tunnel (one tunnel, one hostname per site). Not set up yet | yes, minus keys |

## Updating the Pi

Edit and commit on the PC, then `git push origin main && git push pi main`. The Pi's checkout
updates itself on push (`receive.denyCurrentBranch updateInstead`).

## Sites

| Site | Port | Address on the home network |
|---|---|---|
| vistaclinic | 8081 | http://daviderasberry:8081 |

## Everyday commands

```bash
cd ~/Documents/wordpressServers
bin/new-site.sh acme 8082                 # empty site for a new client, then: cd sites/acme && docker compose up -d
PREFIX=wpkq_ bin/new-site.sh name 8083    # when importing a site whose tables are not wp_
bin/import.sh <site> files.tar.gz db.sql.gz <docroot-in-tar> <new-url> <old-url>...
bin/wp.sh <site> plugin list              # any WP-CLI command
bin/set-url.sh <site> https://new.address # e.g. when the tunnel hostname is added
bin/backup.sh <site>                      # snapshot before a bigger change
bin/r2-upload.sh <site> <label> <file>... # copy backups to R2, download back and compare
cd sites/<site> && docker compose stop    # pause a client's site; "up -d" to resume
```

## What every test copy does differently from the live site

Written by `bin/write-config.sh`, never copied from the client:

- **Own database and passwords**, fresh login keys. The client's `wp-config.php` is deleted on import.
- **No email** (`zz-test-server-guard.php` mu-plugin), so a copy cannot write to real customers.
- **noindex** in the page and in an `X-Robots-Tag` header, whatever the copied database says.
- **No WP-Cron and no automatic updates**, so the copy stays on the live site's versions.
- Per-site extras (e.g. a plugin's own "this is staging" switch) go in `sites/<name>/wp-config-extra.php`.

## Rules

- Never put the client's live database password, or any backup, anywhere that is published.
- The SD card wears out under database writes; move `sites/` and `backups/` to a USB SSD when one is available.
