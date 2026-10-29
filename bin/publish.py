#!/usr/bin/env python3
"""Publish approved changes from a test site to its live site, one piece at a time
(WORKFLOW.md, step B7). Never the whole database.

  bin/publish.py <site> files <path>...     files under wp-content/ (a theme, a plugin, uploads)
  bin/publish.py <site> post <id>...        pages, posts, any post type; an attachment takes
                                            its image files with it
  bin/publish.py <site> option <name>...    single WordPress options
  bin/publish.py <site> rollback <dir>      undo one publish (backups/<site>/<stamp>-publish/)
  bin/publish.py <site> history             list the publishes, newest last

Without --yes nothing is written: it shows what would change on live, and why it would
refuse. With --yes it backs up the live database first, then writes, and keeps everything it
replaced in backups/<site>/<stamp>-publish/ so `rollback` can put it back.

It refuses anything changed on live since the last refresh (it compares with the manifest
refresh.sh recorded), so publishing cannot overwrite an edit somebody made on live. --force
skips that check: use it only after looking at the live change.

Never sent: wp-config.php, .htaccess, caches, the test-server guard, and options that differ
on purpose between a copy and live (home, siteurl, active_plugins, blog_public, ...).
"""
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHP = os.path.join(ROOT, "bin", "php")

# rsync patterns: a leading / anchors at the docroot.
NEVER_FILES = ["/wp-config.php", ".htaccess", ".user.ini", "object-cache.php", "advanced-cache.php",
               "zz-test-server-guard.php", "/wp-content/cache/", "/wp-content/litespeed/",
               "/wp-content/upgrade/"]
NEVER_OPTIONS = {"siteurl", "home", "blog_public", "active_plugins", "active_sitewide_plugins", "cron",
                 "rewrite_rules", "db_version", "initial_db_version", "admin_email", "new_admin_email",
                 "users_can_register", "default_role", "recently_activated", "uninstall_plugins",
                 "template", "stylesheet", "auth_key", "auth_salt", "logged_in_key", "logged_in_salt",
                 "nonce_key", "nonce_salt", "secure_auth_key", "secure_auth_salt"}


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                env[k.strip()] = v
    return env


def report(r, where):
    out = r.stdout.decode(errors="replace")
    if "@@REPORT@@" not in out:
        die(f"{where} did not answer (exit {r.returncode}):\n{out[-1500:]}\n{r.stderr.decode(errors='replace')[-1500:]}", 3)
    return json.loads(out.split("@@REPORT@@", 1)[1])


class Site:
    def __init__(self, name):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
            die("site names are lower-case letters, digits and -")
        self.name = name
        self.dir = os.path.join(ROOT, "sites", name)
        if not os.path.exists(os.path.join(self.dir, "live.env")):
            die(f"{name} is not connected to its live site: run bin/live-setup.sh")
        self.env = read_env(os.path.join(self.dir, ".env"))
        live = read_env(os.path.join(self.dir, "live.env"))
        self.html = os.path.join(self.dir, "html")
        self.docroot = live["LIVE_DOCROOT"].rstrip("/")
        self.live_url = live["LIVE_URLS"].split()[0].rstrip("/")
        self.target = live["LIVE_SSH"]
        keys = os.path.join(ROOT, "secrets", "ssh")
        self.ssh_opts = ["-p", live.get("LIVE_PORT", "22"), "-o", "BatchMode=yes",
                         "-o", f"UserKnownHostsFile={keys}/known_hosts", "-o", "StrictHostKeyChecking=yes"]
        # Same rule as bin/lib/live.sh: the PC's key, lent through pc/pi.sh, unless this
        # client has its own key on the Pi.
        if os.path.exists(os.path.join(keys, name)):
            self.ssh_opts += ["-i", os.path.join(keys, name), "-o", "IdentitiesOnly=yes"]
        elif not os.environ.get("SSH_AUTH_SOCK"):
            die(f"no access to {name}'s live host from here: run this from the PC with pc/pi.sh")
        self.backups = os.path.join(ROOT, "backups", name)
        self.manifest = os.path.join(self.dir, "manifest")
        if not os.path.exists(os.path.join(self.manifest, "posts.tsv")):
            die(f"{name} has no manifest: run bin/refresh.sh {name} --yes first")

    # -- talking to live and to the copy

    def remote(self, command, data=None):
        r = subprocess.run(["ssh", *self.ssh_opts, self.target, command], input=data, capture_output=True)
        if r.returncode:
            die(f"live command failed ({command[:70]}): {r.stderr.decode(errors='replace')[-800:]}", 3)
        return r.stdout.decode(errors="replace")

    def rsync(self, args):
        r = subprocess.run(["rsync", "-e", shlex.join(["ssh", *self.ssh_opts]), *args], capture_output=True, text=True)
        if r.returncode:
            die(f"rsync failed: {r.stderr[-800:]}", 3)
        return r.stdout

    def copy_eval(self, *args):
        with open(os.path.join(PHP, "export.php"), "rb") as f:
            code = f.read()
        r = subprocess.run([os.path.join(ROOT, "bin", "wp.sh"), self.name, "eval-file", "-", *args],
                           input=code, capture_output=True)
        return report(r, "the test copy")

    def live_eval(self, payload):
        """Run apply.php on live. The payload goes up as a 0600 file outside the web root and
        is removed afterwards; the script itself comes over stdin and stays small."""
        with open(os.path.join(PHP, "apply.php"), "rb") as f:
            code = f.read()
        name = f".wp-toolkit-{stamp()}-{os.getpid()}.json"
        self.remote(f"umask 077 && cat > ~/{name}", json.dumps(payload).encode())
        try:
            r = subprocess.run(["ssh", *self.ssh_opts, self.target,
                                f"cd {shlex.quote(self.docroot)} && wp eval-file - ~/{name}"],
                               input=code, capture_output=True)
        finally:
            subprocess.run(["ssh", *self.ssh_opts, self.target, f"rm -f ~/{name}"], capture_output=True)
        return report(r, "live")

    def live_db_backup(self, out):
        subprocess.run([os.path.join(ROOT, "bin", "live-backup.sh"), self.name, "--db-only", "--out", out],
                       check=True, stdout=subprocess.DEVNULL)

    def check_live(self):
        r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", self.live_url + "/"],
                           capture_output=True, text=True)
        print(f"live check: {self.live_url}/ answers {r.stdout}")
        print("(PHP changes can take about a minute to show on hosts with opcache)")

    # -- the manifest recorded at refresh time

    def read_tsv(self, name):
        out = {}
        with open(os.path.join(self.manifest, name)) as f:
            for line in f:
                if "\t" in line:
                    k, v = line.rstrip("\n").split("\t", 1)
                    out[k] = v
        return out

    def write_tsv(self, name, data):
        with open(os.path.join(self.manifest, name), "w") as f:
            f.writelines(f"{k}\t{v}\n" for k, v in data.items())

    def read_files_manifest(self):
        out = {}
        with open(os.path.join(self.manifest, "files.md5")) as f:
            for line in f:
                md5, path = line.rstrip("\n").split("  ", 1)
                out[path] = md5
        return out

    def write_files_manifest(self, data):
        with open(os.path.join(self.manifest, "files.md5"), "w") as f:
            f.writelines(f"{md5}  {path}\n" for path, md5 in sorted(data.items()))

    # -- bookkeeping

    def new_record_dir(self):
        d = os.path.join(self.backups, f"{stamp()}-publish")
        os.makedirs(d, mode=0o700)
        return d

    def log(self, line):
        with open(os.path.join(self.backups, "publish.log"), "a") as f:
            f.write(f"{stamp()} {line}\n")


# -- files

def clean_paths(site, paths):
    out = []
    for p in paths:
        p = os.path.normpath(p).lstrip("/")
        if not p.startswith("wp-content/") or ".." in p.split("/"):
            die(f"only paths under wp-content/ can be published: {p}")
        if not os.path.exists(os.path.join(site.html, p)):
            die(f"not on the test copy: {p}")
        out.append(p)
    return out


def files_plan(site, paths):
    excl = [f"--exclude={x}" for x in NEVER_FILES]
    srcs = [f"{site.html}/./{p}" for p in paths]
    out = site.rsync(["-rlc", "-R", "--dry-run", "--itemize-changes", "--delete", *excl, *srcs,
                      f"{site.target}:{site.docroot}/"])
    new, changed, live_only = [], [], []
    for line in out.splitlines():
        if line.startswith("*deleting"):
            live_only.append(line.split(None, 1)[1])
        elif len(line) > 12 and line[0] in "<>" and line[1] == "f":
            (new if line[2] == "+" else changed).append(line[12:])
    man = site.read_files_manifest()
    conflicts = []
    if changed:
        sums = site.remote(f"cd {shlex.quote(site.docroot)} && xargs -0 md5sum --", "\0".join(changed).encode())
        for line in sums.splitlines():
            md5, path = line.split("  ", 1)
            if man.get(path) != md5:
                conflicts.append(path + ("  (added on live after the refresh)" if path not in man else "  (edited on live after the refresh)"))
    for p in new:
        if p in man:
            conflicts.append(p + "  (deleted on live after the refresh)")
    return new, changed, live_only, conflicts


def show_files(new, changed, live_only, conflicts):
    for p in new:
        print(f"  new      {p}")
    for p in changed:
        print(f"  changed  {p}")
    for p in live_only:
        print(f"  live only, left alone: {p}")
    for c in conflicts:
        print(f"  CONFLICT {c}")


def files_apply(site, paths, new, changed, record):
    home = site.remote("echo $HOME").strip()
    rb = f"{home}/wp-toolkit-backups/{site.name}/{os.path.basename(record)}"
    site.remote(f"mkdir -p {shlex.quote(rb)} && chmod 700 {shlex.quote(rb)}")
    excl = [f"--exclude={x}" for x in NEVER_FILES]
    site.rsync(["-rlc", "-R", "--chmod=D755,F644", "--backup", f"--backup-dir={rb}", *excl,
                *[f"{site.html}/./{p}" for p in paths], f"{site.target}:{site.docroot}/"])
    man = site.read_files_manifest()
    for p in new + changed:
        with open(os.path.join(site.html, p), "rb") as f:
            man[p] = hashlib.md5(f.read()).hexdigest()
    site.write_files_manifest(man)
    return {"remote_backup": rb, "new": new, "changed": changed}


def cmd_files(site, paths, yes, force):
    paths = clean_paths(site, paths)
    new, changed, live_only, conflicts = files_plan(site, paths)
    print(f"publish files to {site.live_url}:")
    show_files(new, changed, live_only, conflicts)
    if not new and not changed:
        print("nothing to publish: live already has exactly these files")
        return
    if conflicts and not force:
        die("not published: live changed after the last refresh (refresh, or look and use --force)", 1)
    if not yes:
        print("\ndry run, nothing written. Add --yes to publish.")
        return
    rec = site.new_record_dir()
    print("== backing up the live database")
    site.live_db_backup(os.path.join(rec, "live-before"))
    print("== copying files (replaced ones are kept on live outside the web root)")
    files = files_apply(site, paths, new, changed, rec)
    save(rec, "record.json", {"kind": "files", "targets": paths, "files": files})
    site.log(f"files {' '.join(paths)} -> {os.path.basename(rec)}")
    print(f"published. Undo: bin/publish.py {site.name} rollback {rec}")
    site.check_live()


# -- posts and options

def show_report(rep):
    for it in rep["items"]:
        what = f"#{it['id']} {it['type']} \"{it['title']}\"" if "id" in it else f"option {it['name']}"
        print(f"  {it['action']:<7} {what}: {', '.join(it['changes']) or 'new on live'}")
    for w in rep["warnings"]:
        print(f"  warning: {w}")
    for e in rep["errors"]:
        print(f"  REFUSED: {e}")


def save(rec, name, data):
    path = os.path.join(rec, name)
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(data, f)


def cmd_content(site, kind, targets, yes, force):
    if kind == "post":
        if not all(t.isdigit() for t in targets):
            die("post IDs are numbers (wp-admin shows them in the edit link: post=123)")
    else:
        for t in targets:
            if t in NEVER_OPTIONS or t.startswith(("_transient", "_site_transient")) or t.endswith("user_roles"):
                die(f"option {t} differs on purpose between a copy and live; it is never published")
    exp = site.copy_eval(kind, *targets)
    man = site.read_tsv("posts.tsv" if kind == "post" else "options.tsv")
    key = (lambda it: str(it["post"]["ID"])) if kind == "post" else (lambda it: it["name"])
    payload = {"kind": kind, "mode": "check", "from": exp["home"], "to": site.live_url, "force": force,
               "manifest": {key(it): man.get(key(it)) for it in exp["items"]}, "items": exp["items"]}

    files = sorted({f for it in exp["items"] for f in it.get("files", [])})
    fplan = files_plan(site, files) if files else None

    print(f"publish {kind} to {site.live_url} (copy: {exp['home']}):")
    rep = site.live_eval(payload)
    show_report(rep)
    if fplan:
        print(" with the attachment files:")
        show_files(*fplan)
    if rep["errors"] or (fplan and fplan[3] and not force):
        die("not published.", 1)
    if not yes:
        print("\ndry run, nothing written. Add --yes to publish.")
        return

    rec = site.new_record_dir()
    print("== backing up the live database")
    site.live_db_backup(os.path.join(rec, "live-before"))
    record = {"kind": kind, "targets": targets, "files": None}
    if fplan and (fplan[0] or fplan[1]):
        print("== copying attachment files")
        record["files"] = files_apply(site, files, fplan[0], fplan[1], rec)
    save(rec, "record.json", record)
    print("== writing to live")
    payload["mode"] = "apply"
    rep = site.live_eval(payload)
    save(rec, "before.json", rep["before"])
    if rep["errors"]:
        show_report(rep)
        die(f"live refused part way. What was written is listed in {rec}; undo: bin/publish.py {site.name} rollback {rec}", 3)
    update_manifest(site, kind, rep["after"])
    site.log(f"{kind} {' '.join(targets)} -> {os.path.basename(rec)}")
    print(f"published. Undo: bin/publish.py {site.name} rollback {rec}")
    site.check_live()


def update_manifest(site, kind, after):
    name = "posts.tsv" if kind == "post" else "options.tsv"
    man = site.read_tsv(name)
    for k, v in after.items():
        if v is None:
            man.pop(k, None)
        else:
            man[k] = v
    site.write_tsv(name, man)


# -- undo

def cmd_rollback(site, rec, yes):
    rec = os.path.abspath(rec)
    with open(os.path.join(rec, "record.json")) as f:
        record = json.load(f)
    before = []
    if record["kind"] in ("post", "option"):
        with open(os.path.join(rec, "before.json")) as f:
            before = json.load(f)
    print(f"rollback of {record['kind']} {' '.join(record['targets'])} ({os.path.basename(rec)}):")
    for b in before:
        what = f"#{b['post']['ID']}" if "post" in b else f"option {b['name']}"
        print(f"  {'remove' if b.get('absent') else 'restore'} {what}")
    files = record.get("files")
    if files:
        for p in files["changed"]:
            print(f"  restore  {p}")
        for p in files["new"]:
            print(f"  remove   {p}")
    if not yes:
        print("\ndry run, nothing written. Add --yes to roll back.")
        return
    out = site.new_record_dir()
    site.live_db_backup(os.path.join(out, "live-before"))
    if before:
        rep = site.live_eval({"kind": record["kind"], "mode": "apply", "from": site.live_url, "to": site.live_url,
                              "force": True, "manifest": {}, "items": before})
        show_report(rep)
        if rep["errors"]:
            die("rollback stopped", 3)
        update_manifest(site, record["kind"], rep["after"])
    if files:
        root = shlex.quote(site.docroot)
        if files["changed"]:
            site.remote(f"cp -a {shlex.quote(files['remote_backup'])}/. {root}/")
        if files["new"]:
            site.remote(f"cd {root} && xargs -0 rm -f --", "\0".join(files["new"]).encode())
        print("files restored (the file manifest is now stale: refresh before publishing files again)")
    site.log(f"rollback {os.path.basename(rec)}")
    print("rolled back.")
    site.check_live()


def main(argv):
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    unknown = flags - {"--yes", "--force"}
    if unknown or len(args) < 2:
        die(__doc__)
    yes, force = "--yes" in flags, "--force" in flags
    site = Site(args[0])
    cmd, rest = args[1], args[2:]
    if cmd == "files" and rest:
        cmd_files(site, rest, yes, force)
    elif cmd in ("post", "option") and rest:
        cmd_content(site, cmd, rest, yes, force)
    elif cmd == "rollback" and len(rest) == 1:
        cmd_rollback(site, rest[0], yes)
    elif cmd == "history" and not rest:
        log = os.path.join(site.backups, "publish.log")
        print(open(log).read() if os.path.exists(log) else "nothing published yet")
    else:
        die(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
