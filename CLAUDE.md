# CLAUDE.md: wordpress-toolkit

Shared tools and rules for every client WordPress site. Anything about one client (theme,
plugins, content rules, reports) lives in that client's own repo, whose `CLAUDE.md` points
back here. `WORKFLOW.md` is the step-by-step; follow it.

## Where things run

- The **Raspberry Pi** (`ssh dnasc@davideRasberry`, Debian 12 arm64, 8 GB, Docker) is the test
  server. This repo is checked out at `~/Documents/wordpressServers`. Other projects share the
  Pi (`~/Documents/minecraft-bot`): touch nothing outside this folder, and keep container,
  network and port names prefixed `wp-`.
- Commits are made on the PC and pushed to GitHub (`junhodigital/wordpress-toolkit`) and to the
  Pi (remote `pi`). The Pi's own GitHub key is a different account; do not push from the Pi.
- Backups go to Cloudflare R2, bucket in `secrets/r2.env`, EU jurisdiction, so the endpoint
  must contain `.eu.`; without it R2 answers AccessDenied. One folder per client.

- Client links: `bin/edge.py`, zone `junhodigital.com` (in the user's own Cloudflare
  account). The token can edit DNS for that zone only, plus tunnels and Access.
  ⛔ Only WordPress containers are ever public: never add a route to the Pi, a database or
  another project, never put the tunnel on the host network, and never switch the tunnel to
  dashboard-managed routes.

## Rules

- ⛔ Never test on a live site, and never copy a whole test database over live. Publish
  approved changes only, after a fresh verified backup.
- ⛔ Never copy a client's `wp-config.php` onto a test site. `bin/write-config.sh` writes ours.
- ⛔ `sites/`, `backups/` and `secrets/` never go in git and are never published. Backups hold
  the client's database password and their customers' data.
- Never print a key. To check `secrets/r2.env`, show names and lengths, not values.
- A backup is verified only by reading it back: the dump ends with `Dump completed`, the
  archive passes `gzip -t`, an upload is downloaded again and compared (`bin/r2-upload.sh`
  does this).
- Test sites: noindex, no email, no WP-Cron, no automatic updates, the client's tracking off,
  and a login in front before a client link goes out.
- Use only our or the client's own accounts, never a previous developer's.
- Check front-end work in a real browser (Playwright) at 402×874, 820×1180, 1440×900 and
  1920×1080. Markup checks alone have missed broken pages before.
- Commit or push only when asked.
