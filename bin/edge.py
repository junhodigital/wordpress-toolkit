#!/usr/bin/env python3
"""Client preview links: a Cloudflare name and login in front of one test site.

  bin/edge.py setup                               once: create the tunnel and start edge/
  bin/edge.py link <site> [email...]              <site>.<zone> -> that site, behind a login
  bin/edge.py access <site> list                  who can log in
  bin/edge.py access <site> add|remove <email>... change who can log in
  bin/edge.py unlink <site>                       take the link down again

The emails in CF_ADMIN_EMAILS (comma separated, secrets/cloudflare.env) are added to every
client. An entry starting with @ (e.g. @clinic.ie) allows that whole email domain.

Order is a safety property: link creates the login BEFORE the DNS name and the route, and
unlink removes the name and the route BEFORE the login, so a site is never reachable
without one. Routes live in edge/config.yml on this Pi; the Cloudflare token can create
names and logins but cannot point the tunnel anywhere.
"""
import base64
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EDGE = os.path.join(ROOT, "edge")
TUNNEL_JSON = os.path.join(EDGE, "tunnel.json")
API = "https://api.cloudflare.com/client/v4"
# How long a client stays logged in before Access asks for a new email code.
SESSION = "168h"


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def read_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


CF = read_env(os.path.join(ROOT, "secrets", "cloudflare.env"))
for key in ("CF_API_TOKEN", "CF_ACCOUNT_ID", "CF_ZONE"):
    if not CF.get(key):
        die(f"{key} missing from secrets/cloudflare.env")
ACCOUNT = f"/accounts/{CF['CF_ACCOUNT_ID']}"


def api(method, path, body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {CF['CF_API_TOKEN']}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        out = json.load(e)
    if not out.get("success"):
        die(f"Cloudflare {method} {path}: {out.get('errors')}", 3)
    return out["result"]


def zone_id():
    zones = api("GET", f"/zones?name={CF['CF_ZONE']}")
    if not zones:
        die(f"zone {CF['CF_ZONE']} not found for this token")
    return zones[0]["id"]


def tunnel_id():
    if not os.path.exists(TUNNEL_JSON):
        die("no tunnel yet; run: bin/edge.py setup")
    with open(TUNNEL_JSON) as f:
        return json.load(f)["TunnelID"]


def site_env_path(site):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", site):
        die("site names are lower-case letters, digits and -")
    path = os.path.join(ROOT, "sites", site, ".env")
    if not os.path.exists(path):
        die(f"no site {site}")
    return path


def set_site_env(site, key, value):
    """Set or (value None) remove one key in sites/<site>/.env, keeping everything else."""
    path = site_env_path(site)
    with open(path) as f:
        lines = [l for l in f.read().splitlines() if not l.startswith(key + "=")]
    if value is not None:
        lines.append(f"{key}={value}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def linked_sites():
    sites = {}
    for site in sorted(os.listdir(os.path.join(ROOT, "sites"))):
        path = os.path.join(ROOT, "sites", site, ".env")
        if os.path.exists(path):
            host = read_env(path).get("PUBLIC_HOST")
            if host:
                sites[site] = host
    return sites


def apply_routes():
    """Write edge/config.yml from the linked sites and restart the tunnel."""
    lines = [
        f"tunnel: {tunnel_id()}",
        "credentials-file: /etc/cloudflared/tunnel.json",
        "no-autoupdate: true",
        "ingress:",
    ]
    for site, host in linked_sites().items():
        lines += [f"  - hostname: {host}", f"    service: http://wp-{site}-wordpress-1:80"]
    lines.append("  - service: http_status:404")
    path = os.path.join(EDGE, "config.yml")
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write("\n".join(lines) + "\n")
    compose = ["docker", "compose", "-f", os.path.join(EDGE, "docker-compose.yml")]
    subprocess.run(compose + ["up", "-d"], check=True)
    subprocess.run(compose + ["restart", "cloudflared"], check=True)


def include(emails):
    out = []
    for e in emails:
        if e.startswith("@"):
            out.append({"email_domain": {"domain": e[1:]}})
        else:
            out.append({"email": {"email": e}})
    return out


def emails_of(policy):
    out = []
    for rule in policy.get("include", []):
        if "email" in rule:
            out.append(rule["email"]["email"])
        elif "email_domain" in rule:
            out.append("@" + rule["email_domain"]["domain"])
    return out


def clean(emails):
    seen = []
    for e in emails:
        e = e.strip().lower()
        if e and e not in seen:
            if not re.fullmatch(r"[^@\s]*@[^@\s]+\.[^@\s]+", e):
                die(f"not an email: {e}")
            seen.append(e)
    return seen


def find_policy(site):
    return next((p for p in api("GET", f"{ACCOUNT}/access/policies") if p["name"] == f"wp-{site}"), None)


def find_app(host):
    return next((a for a in api("GET", f"{ACCOUNT}/access/apps") if a.get("domain") == host), None)


def save_policy(site, emails):
    emails = clean(emails)
    if not emails:
        die("no one would be able to log in; refusing")
    body = {"name": f"wp-{site}", "decision": "allow", "include": include(emails)}
    policy = find_policy(site)
    if policy:
        return api("PUT", f"{ACCOUNT}/access/policies/{policy['id']}", body)
    return api("POST", f"{ACCOUNT}/access/policies", body)


def cmd_setup():
    if os.path.exists(TUNNEL_JSON):
        print("tunnel already exists:", tunnel_id())
    else:
        secret = base64.b64encode(secrets.token_bytes(32)).decode()
        t = api("POST", f"{ACCOUNT}/cfd_tunnel", {"name": "wp-pi", "config_src": "local", "tunnel_secret": secret})
        creds = {"AccountTag": CF["CF_ACCOUNT_ID"], "TunnelSecret": secret, "TunnelID": t["id"]}
        with open(os.open(TUNNEL_JSON, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            json.dump(creds, f)
        print("tunnel created:", t["id"])
    apply_routes()


def cmd_link(site, emails):
    site_env_path(site)
    host = f"{site}.{CF['CF_ZONE']}"
    target = f"{tunnel_id()}.cfargotunnel.com"
    zid = zone_id()
    existing = api("GET", f"/zones/{zid}/dns_records?name={host}")
    if any(r["type"] != "CNAME" or r["content"] != target for r in existing):
        die(f"{host} already exists in DNS for something else; not touching it")

    admins = [e for e in CF.get("CF_ADMIN_EMAILS", "").split(",") if e.strip()]
    # Re-running link (e.g. to apply a new SESSION) keeps everyone already allowed.
    old = find_policy(site)
    policy = save_policy(site, admins + (emails_of(old) if old else []) + emails)
    app = find_app(host)
    body = {
        "name": f"wp-{site}",
        "domain": host,
        "type": "self_hosted",
        "session_duration": SESSION,
        "app_launcher_visible": False,
        "policies": [{"id": policy["id"], "precedence": 1}],
    }
    if app:
        api("PUT", f"{ACCOUNT}/access/apps/{app['id']}", body)
    else:
        api("POST", f"{ACCOUNT}/access/apps", body)
    print(f"login on {host} for: {', '.join(emails_of(policy))}")

    set_site_env(site, "PUBLIC_HOST", host)
    apply_routes()
    if not existing:
        api("POST", f"/zones/{zid}/dns_records",
            {"type": "CNAME", "name": host, "content": target, "proxied": True,
             "comment": "wordpress-toolkit preview link"})
    subprocess.run([os.path.join(ROOT, "bin", "set-url.sh"), site, f"https://{host}"], check=True)
    print(f"done: https://{host}")


def cmd_unlink(site):
    host = read_env(site_env_path(site)).get("PUBLIC_HOST") or f"{site}.{CF['CF_ZONE']}"
    target = f"{tunnel_id()}.cfargotunnel.com"
    zid = zone_id()
    for r in api("GET", f"/zones/{zid}/dns_records?name={host}"):
        if r["type"] == "CNAME" and r["content"] == target:
            api("DELETE", f"/zones/{zid}/dns_records/{r['id']}")
    set_site_env(site, "PUBLIC_HOST", None)
    apply_routes()
    app = find_app(host)
    if app:
        api("DELETE", f"{ACCOUNT}/access/apps/{app['id']}")
    policy = find_policy(site)
    if policy:
        api("DELETE", f"{ACCOUNT}/access/policies/{policy['id']}")
    print(f"{host} is down. The site still runs on the home network; "
          f"bin/set-url.sh {site} http://<pi>:<port> to use it there.")


def cmd_access(site, action, emails):
    site_env_path(site)
    policy = find_policy(site)
    if not policy:
        die(f"{site} has no link; run: bin/edge.py link {site} <email>...")
    current = emails_of(policy)
    if action == "add":
        current += emails
    elif action == "remove":
        gone = clean(emails)
        current = [e for e in current if e not in gone]
    elif action != "list":
        die("access <site> list|add|remove <email>...")
    if action != "list":
        policy = save_policy(site, current)
    print("\n".join(emails_of(policy)))


def main(argv):
    if argv[:1] == ["setup"] and len(argv) == 1:
        cmd_setup()
    elif argv[:1] == ["link"] and len(argv) >= 2:
        cmd_link(argv[1], argv[2:])
    elif argv[:1] == ["unlink"] and len(argv) == 2:
        cmd_unlink(argv[1])
    elif argv[:1] == ["access"] and len(argv) >= 3:
        cmd_access(argv[1], argv[2], argv[3:])
    else:
        die(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
