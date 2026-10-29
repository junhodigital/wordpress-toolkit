# Workflow

The same steps for every client. Commands run on the Pi, in `~/Documents/wordpressServers`.

## A. New client (once)

1. **Get access**: hosting login (SSH if the host offers it) and a WordPress admin account.
   The client's own accounts or ours, never a previous developer's.
2. **First backup of the live site**: files and database. Check it is complete (the database
   dump ends with `Dump completed`), then copy it to R2:
   `bin/r2-upload.sh <client> <date>-live <files.tar.gz> <db.sql.gz>`
3. **Create the test site**: `bin/new-site.sh <client> <port>` (next free port: see README).
   Add `PREFIX=xyz_` in front if the site's tables are not `wp_`.
4. **Connect it to live**: `bin/live-setup.sh <client> <user@host> <port> <docroot> <live-url>...`
   prints a key made for this client only. Add it on the host (hPanel / cPanel → SSH keys),
   then `bin/live-setup.sh <client> --test`.
5. **Test-copy-only changes**: tracking off (each plugin has its own switch; put it in
   `sites/<client>/wp-config-extra.php`), and anything else the copy must not do in
   `sites/<client>/after-import.sh` (plugins to switch off, host-specific files to remove).
   Write down why in `sites/<client>/NOTES.md`.
6. **First copy**: `bin/refresh.sh <client> --yes`. The copy gets its own passwords, noindex,
   no email, no cron and no automatic updates.
7. **Client repo**: create a private repo for the client and fill in its `CLAUDE.md`: phone,
   address, hours, tracking IDs, content rules, where the live site is hosted.
8. **Client link**: `bin/edge.py link <client> <client's email>...` gives them
   `https://<client>.junhodigital.com` behind a login. Change who can log in with
   `bin/edge.py access`; `bin/edge.py unlink` when the work is finished.

## B. Every change

1. **Refresh** the test site from live: `bin/refresh.sh <client>` says what it will do,
   `--yes` does it. That also backs up live to the Pi and R2 (step 2 included) and records
   live's state, so publishing later can tell whether anyone changed live meanwhile.
2. *(done by refresh)*
3. **Make the change on the test site.** Never on live. Note the post IDs you touch (wp-admin
   shows them in the edit link, `post=123`) and the files you change.
4. **Check it**: screenshots at 402×874, 820×1180, 1440×900 and 1920×1080, links, one `h1` per
   page, SEO basics.
5. **The client reviews** on their link and approves, or asks for changes (back to 3).
6. **Preview the publish**, without `--yes` nothing is written:
   `bin/publish.py <client> post 123 456`, `bin/publish.py <client> files wp-content/themes/x`,
   `bin/publish.py <client> option <name>`. It lists every change and refuses if live changed
   since the refresh, or if a page uses an image that is not on live yet (publish that
   attachment's ID in the same command).
7. **Publish**: the same command with `--yes`. It backs up the live database first and keeps
   what it replaced. Undo with `bin/publish.py <client> rollback backups/<client>/<stamp>-publish`.
   Code goes up as files; content goes up page by page. The whole test database never goes
   over live.
8. **Check live**: the page works, tracking still fires, nothing else moved.
9. **Record it**: commit to the client repo with a short note of what changed and when.
   `bin/publish.py <client> history` lists what was published.

Not covered by publish yet: menus (do them on live in wp-admin after approval), deleting
pages or files on live, and plugin activation (do it in wp-admin).

## C. Regular

- **Weekly**: back up every live site to R2: `bin/live-backup.sh <client> --r2`.
- **Monthly**: report per client (traffic, ads, search); plugin and WordPress updates, tried on
  the test site first.
- Pause test sites nobody is reviewing: `cd sites/<client> && docker compose stop`.

## Rules that never change

- A backup before every change, and a backup counts only after it is verified.
- Never test on the live site. Never copy a whole test database over live.
- Test sites are private: login, noindex, no email, no tracking.
- Keys and backups never go in chat or in git.
- Each client's work uses the client's own accounts.
