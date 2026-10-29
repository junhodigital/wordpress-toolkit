# Workflow

The same steps for every client. Tools marked *(to build)* do not exist yet; until they do,
that step is done by hand.

## A. New client (once)

1. **Get access**: hosting login (SSH if the host offers it) and a WordPress admin account.
   The client's own accounts or ours, never a previous developer's.
2. **First backup of the live site**: files and database. Check it is complete (the database
   dump ends with `Dump completed`), then copy it to R2:
   `bin/r2-upload.sh <client> <date>-live <files.tar.gz> <db.sql.gz>`
3. **Create the test site**: `bin/new-site.sh <client> <port>` (next free port: see README).
   Add `PREFIX=xyz_` in front if the site's tables are not `wp_`.
4. **Import** the backup: `bin/import.sh …`. The copy gets its own passwords, noindex, no email,
   no cron and no automatic updates. Turn off the client's tracking on the copy too (each
   plugin has its own switch; put it in `sites/<client>/wp-config-extra.php`).
5. **Client repo**: create a private repo for the client and fill in its `CLAUDE.md`: phone,
   address, hours, tracking IDs, content rules, where the live site is hosted.
6. **Client link**: `bin/edge.py link <client> <client's email>...` gives them
   `https://<client>.junhodigital.com` behind a login. Change who can log in with
   `bin/edge.py access`; `bin/edge.py unlink` when the work is finished.

## B. Every change

1. **Refresh** the test site from live, so the work starts from current content *(to build:
   `bin/refresh.sh`; until then a new backup plus `import.sh` into an emptied site)*.
2. **Back up live** to R2.
3. **Make the change on the test site.** Never on live.
4. **Check it**: screenshots at 402×874, 820×1180, 1440×900 and 1920×1080, links, one `h1` per
   page, SEO basics.
5. **The client reviews** on their link and approves, or asks for changes (back to 3).
6. **Back up live again**, right before publishing.
7. **Publish only the approved changes** to live *(to build: `bin/publish.sh`)*. Code goes up
   as files; content goes up page by page. The whole test database never goes over live.
8. **Check live**: the page works, tracking still fires, nothing else moved.
9. **Record it**: commit to the client repo with a short note of what changed and when.

## C. Regular

- **Weekly**: back up every live site to R2.
- **Monthly**: report per client (traffic, ads, search); plugin and WordPress updates, tried on
  the test site first.
- Pause test sites nobody is reviewing: `cd sites/<client> && docker compose stop`.

## Rules that never change

- A backup before every change, and a backup counts only after it is verified.
- Never test on the live site. Never copy a whole test database over live.
- Test sites are private: login, noindex, no email, no tracking.
- Keys and backups never go in chat or in git.
- Each client's work uses the client's own accounts.
