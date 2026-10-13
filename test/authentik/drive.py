#!/usr/bin/env python3
"""Drive a real authentik for the integration test (spec 8.3).

    setup                        import the blueprint, create users, the
                                 service account, its permission and the
                                 LDAP outpost; write .state/it.env
    flow <user> <pw> <outfile>   log in, run the WiFi password flow, tamper
                                 with the posted value, write the shown
                                 passphrase; fail unless the stored hash
                                 belongs to the shown passphrase
    denied <user> <pw>           exit 0 if the flow refuses this user
    active <user> 0|1            deactivate / reactivate
    nohash <hash>                exit 0 if no event contains this value
"""
import http.cookiejar
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
STATE = HERE / ".state"
BASE = "http://127.0.0.1:19000"
TOKEN = "it-bootstrap-token-not-a-real-one"
sys.path.insert(0, str(ROOT / "authentik"))
md4_ns = {}
exec((ROOT / "authentik" / "src" / "md4.py").read_text(encoding="utf-8"), md4_ns)


def api(method, path, data=None, raw=None, ctype="application/json"):
    body = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    req = urllib.request.Request(f"{BASE}/api/v3{path}", method=method, data=body,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req) as resp:
            text = resp.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as exc:
        sys.exit(f"{method} {path}: HTTP {exc.code} {exc.read()[:800]!r}")


def one(path):
    results = api("GET", path)["results"]
    if len(results) != 1:
        sys.exit(f"expected one result for {path}, got {len(results)}")
    return results[0]


def import_blueprint():
    content = (ROOT / "authentik" / "blueprints" / "wlan-passwort.yaml").read_bytes()
    boundary = uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"wlan-passwort.yaml\"\r\n"
            "Content-Type: application/x-yaml\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
    result = api("POST", "/managed/blueprints/import/", raw=body, ctype=f"multipart/form-data; boundary={boundary}")
    if not result.get("success"):
        #  The log starts with one "Created Event" per object; only the
        #  warnings and errors say why the import failed.
        logs = [entry for entry in result.get("logs") or [] if entry.get("log_level") not in ("debug", "info")]
        sys.exit("blueprint import failed:\n" + json.dumps(logs or result.get("logs"), indent=1)[:4000])


def wait_for_defaults(timeout=300):
    """Wait until the worker has applied authentik's own blueprints.

    /-/health/ready/ answers long before that. Until the bootstrap blueprint
    has run the token is "invalid/expired"; until the default flows exist our
    blueprint's !Find on default-invalidation-flow resolves to null.
    """
    deadline = time.monotonic() + timeout
    while True:
        req = urllib.request.Request(f"{BASE}/api/v3/managed/blueprints/?page_size=500",
                                     headers={"Authorization": f"Bearer {TOKEN}"})
        try:
            with urllib.request.urlopen(req) as resp:
                pending = [b["path"] for b in json.loads(resp.read())["results"] if b["status"] == "unknown"]
        except urllib.error.HTTPError as exc:
            pending = [f"HTTP {exc.code}"]
        if not pending:
            return
        if time.monotonic() > deadline:
            sys.exit(f"authentik's own blueprints were not applied in {timeout}s: {pending}")
        time.sleep(5)


def setup():
    wait_for_defaults()
    import_blueprint()
    wlan = one("/core/groups/?name=wlan")["pk"]
    search = one("/core/groups/?name=wlan-ldap-search")["pk"]
    for name, groups in (("peapuser", [wlan]), ("outsider", [])):
        pk = api("POST", "/core/users/", {"username": name, "name": name, "groups": groups})["pk"]
        api("POST", f"/core/users/{pk}/set_password/", {"password": "it-user-pw-0123456789"})
    sa = api("POST", "/core/users/service_account/", {"name": "svc-wlan-ldap", "create_group": False, "expiring": False})
    api("POST", f"/core/groups/{search}/add_user/", {"pk": sa["user_pk"]})
    provider = one("/providers/ldap/?name=wlan-ldap")["pk"]
    role = api("POST", "/rbac/roles/", {"name": "wlan-ldap-search"})["pk"]
    api("POST", f"/rbac/permissions/assigned_by_roles/{role}/assign/",
        {"permissions": ["authentik_providers_ldap.search_full_directory"],
         "model": "authentik_providers_ldap.ldapprovider", "object_pk": str(provider)})
    api("PATCH", f"/core/groups/{search}/", {"roles": [role]})
    outpost = api("POST", "/outposts/instances/", {"name": "wlan-ldap", "type": "ldap", "providers": [provider],
                                                   "config": {"authentik_host": "http://server:9000"}})
    ident = one(f"/core/tokens/?identifier=ak-outpost-{outpost['pk']}-api")["identifier"]
    key = api("GET", f"/core/tokens/{ident}/view_key/")["key"]
    (STATE / "it.env").write_text(f"IT_LDAP_TOKEN={key}\nIT_LDAP_BIND_PASSWORD={sa['token']}\n", encoding="utf-8")
    print("setup done")


class Browser:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def executor(self, slug, body=None):
        csrf = next((c.value for c in self.jar if c.name == "authentik_csrf"), "")
        req = urllib.request.Request(f"{BASE}/api/v3/flows/executor/{slug}/?query=",
                                     method="POST" if body else "GET",
                                     data=json.dumps(body).encode() if body else None,
                                     headers={"Content-Type": "application/json", "X-authentik-CSRF": csrf,
                                              "Referer": BASE})
        with self.opener.open(req) as resp:
            return json.loads(resp.read())

    def login(self, user, password):
        self.opener.open(f"{BASE}/if/flow/default-authentication-flow/").read()
        self.executor("default-authentication-flow")
        self.executor("default-authentication-flow", {"component": "ak-stage-identification", "uid_field": user})
        c = self.executor("default-authentication-flow", {"component": "ak-stage-password", "password": password})
        if c["component"] != "xak-flow-redirect":
            sys.exit(f"login of {user} failed: {c}")

    def start_wlan(self):
        self.opener.open(f"{BASE}/if/flow/wlan-passwort/").read()
        return self.executor("wlan-passwort")


def field(challenge, key):
    return next((f.get("initial_value") for f in challenge.get("fields", []) if f["field_key"] == key), None)


def stored_hash(user):
    return one(f"/core/users/?username={user}")["attributes"].get("wifi-password-nthash")


def flow(user, password, outfile):
    b = Browser()
    b.login(user, password)
    c = b.start_wlan()
    shown = field(c, "wifi_password")
    if c["component"] != "ak-stage-prompt" or not shown:
        sys.exit(f"no passphrase shown: {c}")
    info = field(c, "wifi_info") or ""
    if "WLAN" not in info or "radius.example.com" not in info:
        sys.exit(f"info field does not show SSID and certificate name: {info!r}")
    if field(b.executor("wlan-passwort"), "wifi_password") != shown:
        sys.exit("a re-render showed a different passphrase")
    c = b.executor("wlan-passwort", {"component": "ak-stage-prompt", "wifi_ack": False})
    if c["component"] != "ak-stage-prompt" or stored_hash(user) == md4_ns["md4"](shown.encode("utf-16-le")).hex().upper():
        sys.exit("submitting without the checkbox saved the password")
    c = b.executor("wlan-passwort", {"component": "ak-stage-prompt", "wifi_password": "attacker-chosen", "wifi_ack": True})
    if c["component"] != "xak-flow-redirect":
        sys.exit(f"flow did not finish: {c}")
    if stored_hash(user) != md4_ns["md4"](shown.encode("utf-16-le")).hex().upper():
        sys.exit("the stored hash does not belong to the shown passphrase")
    pathlib.Path(outfile).write_text(shown, encoding="utf-8")
    print(f"{user}: passphrase stored")


def denied(user, password):
    b = Browser()
    b.login(user, password)
    c = b.start_wlan()
    sys.exit(0 if c["component"] == "ak-stage-access-denied" else f"flow not refused: {c['component']}")


def active(user, flag):
    pk = one(f"/core/users/?username={user}")["pk"]
    api("PATCH", f"/core/users/{pk}/", {"is_active": flag == "1"})


def nohash(value):
    events = json.dumps(api("GET", "/events/events/?page_size=1000&ordering=-created")["results"])
    sys.exit(0 if value not in events else "the hash appears in the event log")


if __name__ == "__main__":
    STATE.mkdir(exist_ok=True)
    cmd, args = sys.argv[1], sys.argv[2:]
    {"setup": setup, "flow": flow, "denied": denied, "active": active, "nohash": nohash}[cmd](*args)
