#!/usr/bin/env python3
"""Make sure TestFlight builds reach the right people, via the App Store Connect API.

Creates (if missing) an internal beta group with access to all builds, and adds each tester
email to it. Internal testers must be users of the App Store Connect team (the account holder
is). Idempotent: safe to run on every CI build.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, TESTER_EMAILS (comma separated),
     BETA_GROUP (optional, default "Wanderer team").
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
import jwt  # pyjwt[crypto]

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


TOKEN = token()


def call(method, path, body=None, query=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} failed: {e.code} {e.read().decode()[:500]}")


def main():
    bundle = os.environ.get("BUNDLE_ID", "wander.wowfrang.com")
    emails = [e.strip() for e in os.environ.get("TESTER_EMAILS", "").split(",") if e.strip()]
    group_name = os.environ.get("BETA_GROUP", "Wanderer team")
    if not emails:
        print("No TESTER_EMAILS set; nothing to do.")
        return

    app_id = os.environ.get("ASC_APP_ID")
    if app_id:
        app = call("GET", f"/apps/{app_id}")["data"]
        print(f"App {app_id}: {app['attributes'].get('name')} ({app['attributes'].get('bundleId')})")
    else:
        apps = call("GET", "/apps", query={"filter[bundleId]": bundle})["data"]
        if not apps:
            listed = call("GET", "/apps", query={"limit": 50})["data"]
            found = ", ".join(f"{a['id']}={a['attributes'].get('bundleId')}" for a in listed) or "none"
            sys.exit(f"No App Store Connect app with bundle ID {bundle}. Apps this key can see: {found}")
        app_id = apps[0]["id"]

    groups = call("GET", f"/apps/{app_id}/betaGroups", query={"limit": 200})["data"]
    group = next((g for g in groups if g["attributes"]["name"] == group_name), None)
    if group is None:
        group = call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": group_name, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})["data"]
        print(f"Created internal group '{group_name}' with access to all builds")
    group_id = group["id"]

    members = call("GET", f"/betaGroups/{group_id}/betaTesters", query={"limit": 200})["data"]
    present = {(m["attributes"].get("email") or "").lower() for m in members}
    for email in emails:
        if email.lower() in present:
            print(f"{email} is already in '{group_name}'")
            continue
        existing = call("GET", "/betaTesters", query={"filter[email]": email})["data"]
        if existing:
            call("POST", f"/betaGroups/{group_id}/relationships/betaTesters",
                 {"data": [{"type": "betaTesters", "id": existing[0]["id"]}]})
        else:
            call("POST", "/betaTesters", {"data": {
                "type": "betaTesters",
                "attributes": {"email": email},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}},
            }})
        print(f"Added {email} to '{group_name}'")


if __name__ == "__main__":
    main()
