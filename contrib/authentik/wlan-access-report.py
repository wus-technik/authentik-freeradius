#!/usr/bin/env python3
"""Who can join the WiFi with PEAP, and who cannot yet (issue #9).

Before a cutover from a RADIUS that let every directory account in, compare
that set with the users this stack accepts: active members of the WLAN group
with a WiFi password. Run it again during the rollout to see who still has to
fetch a password.

    AUTHENTIK_URL=https://auth.example.com \\
    AUTHENTIK_API_TOKEN=<token> \\
    contrib/authentik/wlan-access-report.py --group wlan [--json]

The token needs read access to users and groups. Nothing is changed. The
report shows whether a WiFi password exists, never the hash.

Membership is direct membership, as in the LDAP filter FreeRADIUS uses.
Service accounts are left out. "Active users outside the group" is the
difference to a RADIUS without a user filter -- if authentik holds the whole
directory; accounts that only exist in the directory do not appear at all.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30
SERVICE_TYPES = {"service_account", "internal_service_account"}


def get(base, token, path):
    req = urllib.request.Request(base + "/api/v3" + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.exit(f"GET {path}: HTTP {exc.code} {exc.read()[:300]!r}")
    except urllib.error.URLError as exc:
        sys.exit(f"GET {path}: {exc.reason}")


def all_pages(base, token, path):
    page = 1
    while True:
        sep = "&" if "?" in path else "?"
        data = get(base, token, f"{path}{sep}page={page}&page_size=100")
        yield from data["results"]
        if not data["pagination"].get("next"):
            return
        page += 1


def report(base, token, group_name):
    groups = get(base, token, "/core/groups/?" + urllib.parse.urlencode({"name": group_name}))["results"]
    if len(groups) != 1:
        sys.exit(f"group {group_name!r}: found {len(groups)} groups with that name, expected one")
    group = groups[0]["pk"]

    result = {"group": group_name, "can_join": [], "no_wifi_password": [],
              "deactivated_members": [], "outside_group": []}
    for user in all_pages(base, token, "/core/users/?include_groups=false"):
        if user.get("type") in SERVICE_TYPES:
            continue
        name = user["username"]
        member = group in user.get("groups", [])
        has_password = bool((user.get("attributes") or {}).get("wifi-password-nthash"))
        if member and not user["is_active"]:
            result["deactivated_members"].append(name)
        elif member and has_password:
            result["can_join"].append(name)
        elif member:
            result["no_wifi_password"].append(name)
        elif user["is_active"]:
            result["outside_group"].append(name + (" (external)" if user.get("type") == "external" else ""))
    for names in result.values():
        if isinstance(names, list):
            names.sort(key=str.lower)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--group", required=True, help="the WLAN group, e.g. the blueprint's wlan_group")
    parser.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = parser.parse_args()
    #  Names are rarely plain ASCII, and -I ignores PYTHONIOENCODING: on
    #  Windows the output would otherwise be cp1252.
    sys.stdout.reconfigure(encoding="utf-8")
    base = os.environ.get("AUTHENTIK_URL", "").rstrip("/")
    token = os.environ.get("AUTHENTIK_API_TOKEN", "")
    if not base or not token:
        sys.exit("set AUTHENTIK_URL and AUTHENTIK_API_TOKEN")

    result = report(base, token, args.group)
    if args.json:
        json.dump(result, sys.stdout, indent=2)
        print()
        return
    print(f"WLAN group: {result['group']}")
    for key, title in (("can_join", "Can join with PEAP"),
                       ("no_wifi_password", "Members without a WiFi password"),
                       ("deactivated_members", "Deactivated members"),
                       ("outside_group", "Active users outside the group")):
        print(f"\n{title} ({len(result[key])}):")
        for name in result[key]:
            print(f"  {name}")


if __name__ == "__main__":
    main()
