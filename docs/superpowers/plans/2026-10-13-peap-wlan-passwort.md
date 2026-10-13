# PEAP-MSCHAPv2 mit generiertem WLAN-Passwort: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nutzer melden sich auf allen Plattformen ohne Profil per PEAP-MSCHAPv2 mit einem in authentik erzeugten WLAN-Passwort an. Vorher bekommen beide Outposts feste Adressen (#15).

**Architecture:**
- **Feste Adressen:** Beide Outposts liegen auf festen IPv4-Adressen im Compose-Netz, DNS ist aus dem Pfad.
- **FreeRADIUS:** Ein Schalter `PEAP_ENABLE` bindet über generierte Include-Dateien einen `peap`-Block, das `ldap`-Modul und einen eigenen inneren Virtual Server ein. Der innere Server holt den NT-Hash über den authentik-LDAP-Outpost.
- **authentik:** Ein Blueprint liefert den Flow, der die Passphrase erzeugt, in der Session hält und beim Bestätigen den NT-Hash speichert.

**Tech Stack:** FreeRADIUS 3.2.10 (`freeradius/freeradius-server:3.2.10-alpine`), POSIX sh, bash, Docker Compose, authentik 2026.8.3 (Blueprints, Expression-Policies), OpenLDAP 2.6 (Alpine 3.21) als Test-Stand-in, Python 3 (nur Standardbibliothek), `eapol_test`.

**Spec:** `docs/superpowers/specs/2026-10-13-peap-wlan-passwort-design.md` (Revision 4). Wer eine Aufgabe umsetzt, liest den Spec-Abschnitt, auf den die Aufgabe verweist.

## Global Constraints

- Branch: `feat/peap-wlan-passwort` von `develop`. Kein Push und kein PR ohne ausdrückliches Okay von Christian.
- Commit-Messages auf Deutsch. Jede endet mit einer Leerzeile und `Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN`. Kein Co-Author-Trailer. Issue-Bezug im Body: `Closes #15` (Task 1), sonst `Refs #14`.
- **Sprache:**
  - Code-Kommentare, Log-Zeilen und die Repo-Doku unter `docs/` und im README bleiben Englisch, wie alle bestehenden Dateien.
  - Für Nutzer sichtbare authentik-Texte (Prompt-Labels, Meldungen) und die Rundmail-Vorlage sind Deutsch.
- **Öffentliches Repo:** keine Site-Daten (Hostnamen, IPs, Domains realer Installationen). Beispiele nutzen `example.com` und die Standard-Subnetze dieses Plans.
- **Dateien:** LF-Zeilenenden (`.gitattributes`). Manche Working-Copy-Dateien haben CRLF. Mit dem Edit-Tool bearbeiten, nicht mit `str.replace("\n…")`.
- **Shell:** `shellcheck` sauber, wie im CI-Job `lint`. Unter Git Bash auf Windows braucht Docker bei Volumes mit `MSYS_NO_PATHCONV=1` einen Windows-Pfad (`cygpath -w`); `run.sh` setzt `MSYS_NO_PATHCONV=1` schon.
- **Produktions-Standardwerte:**
  - `RADIUS_NET_SUBNET=172.31.253.0/24`, `RADIUS_NET_DYNAMIC=172.31.253.128/25`
  - `AUTHENTIK_RADIUS_IP=172.31.253.10`, `AUTHENTIK_LDAP_IP=172.31.253.11`
- **e2e-Netz:** `172.28.0.0/16`, dynamisch `172.28.128.0/17`, RADIUS-Stand-in `172.28.0.10`, LDAP-Stand-in `172.28.0.11`.
- **Integrationstest-Netz:** `172.29.0.0/16`, dynamisch `172.29.128.0/17`, LDAP-Outpost `172.29.0.11`.
- **Namen in authentik:**
  - Attribute `wifi-password-nthash` (32 Hex-Zeichen, Großbuchstaben) und `wifi-password-set-at` (ISO 8601, UTC)
  - Session-Schlüssel `wifi_password_pending` = `{"pw": …, "base": …}`
  - Flow-Slug `wlan-passwort`, Prompt-Stage `wlan-passwort-anzeige`, Policy `wlan-passwort-speichern`
  - Felder `wifi_password` (`text_read_only`), `wifi_info` (`static`), `wifi_ack` (`checkbox`)
  - Anwendung `wlan-zugang`; LDAP-Provider und -Anwendung `wlan-ldap`; Bind-Flow `wlan-ldap-bind`
  - Gruppen `wlan` und `wlan-ldap-search`; Servicekonto `svc-wlan-ldap`
- **Passphrase:** sechs Wörter aus der EFF Short Wordlist 1, Kleinbuchstaben, Bindestrich als Trenner, `yo-yo` ausgeschlossen, also 1295 Wörter.
- **PEAP-Schalter:** `PEAP_ENABLE` ist `true` oder `false`, Standard `false`. `default_eap_type` bleibt `ttls`.
- **Adressen:** `AUTHENTIK_RADIUS_HOST` und `LDAP_HOST` müssen literale IPv4-Adressen sein.
- **DNs** (`LDAP_BASE_DN`, `LDAP_BIND_DN`, `LDAP_WLAN_GROUP_DN`): `^[A-Za-z0-9=,._ -]{1,256}$`, kein Zeilenumbruch.
- **GitHub Actions:** nur Majors mit `using: node24`. `actions/checkout@v7` ist im Repo bereits in Gebrauch.

## Review Focus

1. **Benutzername mit LDAP-Sonderzeichen** (`*`, `peapuser)(cn=*`): darf keinen Treffer erzeugen. Test in Task 3, Schritt 1.
2. **Bestehende Installation, Update auf feste Adressen:** Das vorhandene Netz hat ein anderes Subnetz. Aktuelles Compose legt es selbst neu an (vorab geprüft). Die Doku nennt den Ausweg für ältere Versionen. Verifikation in Task 1, Schritt 7.
3. **Passphrase nach dem Speichern erneut angezeigt**, weil das Löschen aus der Session verloren ging: muss trotzdem eine neue sein. Unit-Test in Task 5, Schritt 1 (`test_new_passphrase_after_save_even_if_session_kept`).
4. **Hostname statt IP** in `AUTHENTIK_RADIUS_HOST` oder `LDAP_HOST`: Abbruch mit klarer Meldung, kein stilles Auflösen. Tests in Task 1, Schritt 1 und Task 2, Schritt 1.
5. **Innere Reply-Attribute (MS-CHAP2-Success) im äußeren Accept:** dürfen nicht nach außen. Test in Task 3, Schritt 1, mit Gegenprobe in Schritt 5.

---

### Task 1: Feste Outpost-Adressen statt Namensauflösung (#15)

Spec § 6.0. Danach gibt es kein Auflösen und keinen Adress-Watcher mehr.

**Files:**
- Modify: `freeradius/entrypoint.sh` (Kopfkommentar Z. 3–5, Block Z. 116–164)
- Modify: `docker-compose.yml`, `.env.example`
- Modify: `test/e2e/docker-compose.test.yml`, `test/e2e/run.sh`
- Modify: `docs/troubleshooting.md` (Abschnitt „Authentication stopped after the outpost alone was recreated“), `docs/monitoring.md` (Zeile `outpost address changed`), `README.md`

**Interfaces:**
- Produces: Shell-Funktion `is_ipv4 <string>` in `entrypoint.sh`, Exit-Status 0 nur für eine Dotted-Quad-Adresse ohne führende Nullen; Task 2 nutzt sie für `LDAP_HOST`.
- Produces in `run.sh`:
  - `auth [docker-compose-run-args…]`: führt den Client-Container aus; Exit 0 bei Access-Accept.
  - `service_ip <service>`: IPv4-Adresse des Containers.
  - `started_at <service>`: `.State.StartedAt` des Containers.
  - `rejects <expected-substring> <VAR=value>…`: startet `freeradius` mit diesen Variablen und verlangt Abbruch mit der Meldung.

  Task 2 und 3 nutzen alle vier.

- [ ] **Step 1: e2e-Test zuerst anpassen**

`test/e2e/docker-compose.test.yml`: Der RADIUS-Stand-in bekommt eine feste Adresse, FreeRADIUS die IP, das Netz ein `ip_range`, `OUTPOST_RESOLVE_INTERVAL` entfällt.

```yaml
  authentik_radius:
    build: ./backend
    networks:
      e2e:
        # Fixed, like in production (issue #15).
        ipv4_address: 172.28.0.10
```

Im Dienst `freeradius`, Block `environment`:

```yaml
      AUTHENTIK_RADIUS_HOST: 172.28.0.10
```

Die Zeile `OUTPOST_RESOLVE_INTERVAL: 5` löschen. Den Kommentar über `restart: unless-stopped` ersetzen durch `# Stage "radiusd restarted" and the certificate watcher rely on this.`

Netz am Dateiende:

```yaml
networks:
  e2e:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
          # Dynamic addresses come from the upper half only, so the fixed
          # outpost addresses below it can never be taken.
          ip_range: 172.28.128.0/17
```

`test/e2e/run.sh`:

1. Die Stufen-Überschriften verlieren ihre Zählung: `== 1/6 baseline authentication ==` wird `== baseline authentication ==` und so weiter für alle sechs. Die Gesamtzahl ändert sich in den nächsten Tasks.
2. `cleanup()` lautet jetzt:

```bash
cleanup() {
	docker rm -f akfr-e2e-nopeap >/dev/null 2>&1 || true
	"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
```

3. `auth()` reicht zusätzliche Argumente an `docker compose run` durch, und die Helfer kommen dazu, direkt unter `auth()`:

```bash
auth() { "${COMPOSE[@]}" run --rm --quiet-pull "$@" client >/dev/null 2>&1; }

service_ip() {
	docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
		"$("${COMPOSE[@]}" ps -q "$1")"
}

started_at() {
	docker inspect --format '{{.State.StartedAt}}' "$("${COMPOSE[@]}" ps -q "$1")"
}

# rejects <expected message> VAR=value...: freeradius must refuse to start with
# these variables and say why. timeout keeps a regression -- a container that
# starts after all -- from hanging the suite.
rejects() {
	expect="$1"
	shift
	args=()
	for kv in "$@"; do args+=(-e "$kv"); done
	if out="$(timeout 60 "${COMPOSE[@]}" run --rm --no-deps "${args[@]}" freeradius 2>&1)"; then
		fail "freeradius started with $*; expected it to refuse: $expect"
	fi
	printf '%s\n' "$out" | grep -qF "$expect" \
		|| fail "freeradius refused $* without saying '$expect'. Output: $out"
}
```

4. Die Stufe `== 5/6 outpost recreated alone, on a new address ==` samt Squatter (bis einschließlich `docker rm -f akfr-e2e-squatter …` und `echo "   ok"`) ersetzen durch:

```bash
echo "== outpost recreated alone keeps its address =="
# An image update replaces the outpost container. With a fixed address it comes
# back where radiusd expects it, so authentication resumes without a radiusd
# restart (issue #15).
before="$(started_at freeradius)"
"${COMPOSE[@]}" rm -sf authentik_radius >/dev/null 2>&1
"${COMPOSE[@]}" up -d --no-deps authentik_radius >/dev/null 2>&1
ip="$(service_ip authentik_radius)"
[ "$ip" = 172.28.0.10 ] || fail "the outpost came back on '$ip', not on its fixed 172.28.0.10"
deadline=$(( $(date +%s) + 90 ))
until auth; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "authentication did not resume within 90s after the outpost was recreated"
	sleep 5
done
[ "$(started_at freeradius)" = "$before" ] || fail "radiusd restarted although the outpost kept its address"
echo "   ok"

echo "== configuration the entrypoint must refuse =="
rejects "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address" AUTHENTIK_RADIUS_HOST=authentik_radius
rejects "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address" AUTHENTIK_RADIUS_HOST=172.28.0.010
rejects "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address" AUTHENTIK_RADIUS_HOST=172.28.0.256
echo "   ok"
```

- [ ] **Step 2: Test laufen lassen, er muss scheitern**

Run: `./test/e2e/run.sh`
Expected: FAIL in der Stufe `configuration the entrypoint must refuse` mit `freeradius started with AUTHENTIK_RADIUS_HOST=authentik_radius`. Der alte Entrypoint löst den Namen noch auf. Die Stufe davor läuft, weil die Compose-Datei jetzt schon eine feste Adresse vergibt.

- [ ] **Step 3: entrypoint.sh umbauen**

Kopfkommentar Z. 3–5 ersetzen:

```sh
# Validates the environment, generates the healthcheck secret, optionally
# watches the TLS certificate for renewal, then hands off to radiusd.
```

Den gesamten Block von `# radiusd resolves a home server name once, at startup, …` (Z. 116) bis einschließlich des `fi` nach `watch_outpost_address "$$" &` (Z. 164) ersetzen durch:

```sh
# The outpost has a fixed address on the radius network (issue #15). A name is
# refused: once its container is stopped, Docker forwards the name to the
# host's resolver, which may answer with an address that is not ours -- and
# radiusd would then proxy inner PAP requests to it.
is_ipv4() {
	case "$1" in
		*'
'*) return 1 ;;
	esac
	octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
	printf '%s\n' "$1" | grep -qxE "($octet\.){3}$octet"
}

is_ipv4 "$AUTHENTIK_RADIUS_HOST" \
	|| die "AUTHENTIK_RADIUS_HOST must be a literal IPv4 address (got '$AUTHENTIK_RADIUS_HOST') - give the outpost a fixed address, see docker-compose.yml"

if [ -n "${OUTPOST_RESOLVE_INTERVAL:-}" ]; then
	echo "entrypoint: OUTPOST_RESOLVE_INTERVAL has no effect any more - the outpost has a fixed address" >&2
fi
```

- [ ] **Step 4: Produktions-Compose und `.env.example`**

`docker-compose.yml`:
- Kopfkommentar um diesen Absatz ergänzen, direkt nach der Zeile mit `.env.example`:

```yaml
#  Both outposts sit on fixed addresses of the radius network (issue #15).
#  Upgrading from a version without them: Compose recreates the network on
#  the next deploy; see docs/troubleshooting.md if it does not.
```

- Im Dienst `authentik_radius` `networks: [radius]` ersetzen durch:

```yaml
    networks:
      radius:
        ipv4_address: ${AUTHENTIK_RADIUS_IP:-172.31.253.10}
```

- In `freeradius.environment`: `AUTHENTIK_RADIUS_HOST: ${AUTHENTIK_RADIUS_IP:-172.31.253.10}`. Die Zeile `OUTPOST_RESOLVE_INTERVAL: …` löschen.
- Netz am Ende:

```yaml
networks:
  radius:
    driver: bridge
    ipam:
      config:
        - subnet: ${RADIUS_NET_SUBNET:-172.31.253.0/24}
          #  Docker hands out dynamic addresses (freeradius, a recreated
          #  container) from this range only, so the fixed outpost addresses
          #  below it are always free.
          ip_range: ${RADIUS_NET_DYNAMIC:-172.31.253.128/25}
```

`.env.example`: den Block `OUTPOST_RESOLVE_INTERVAL` (Kommentar plus Zeile) ersetzen durch:

```sh
#  --- internal network -----------------------------------------------------
#  The private network between FreeRADIUS and the authentik outposts. Each
#  outpost has a fixed address in it, so nothing depends on DNS (issue #15).
#  Change the subnet only if it collides with a network on the host or LAN;
#  the addresses below must lie inside it but outside RADIUS_NET_DYNAMIC.
RADIUS_NET_SUBNET=172.31.253.0/24
RADIUS_NET_DYNAMIC=172.31.253.128/25
AUTHENTIK_RADIUS_IP=172.31.253.10
```

- [ ] **Step 5: e2e laufen lassen, er muss bestehen**

Run: `./test/e2e/run.sh`
Expected: `PASS: all end-to-end checks succeeded`

- [ ] **Step 6: Lint**

Run: `shellcheck freeradius/entrypoint.sh freeradius/healthcheck.sh test/e2e/client/auth.sh test/e2e/run.sh`
Expected: keine Ausgabe, Exit 0.

Run: `docker compose -f docker-compose.yml --env-file .env.example config >/dev/null && echo ok`
Expected: `ok`

- [ ] **Step 7: Update einer bestehenden Installation nachstellen (Review Focus 2)**

Vorab mit Compose 5.5.1 geprüft: Compose erkennt die geänderte Netz-Konfiguration, legt das Netz neu an und erzeugt die Container neu. Der Outpost landet auf seiner festen Adresse. Hier mit den echten Dateien bestätigen:

```bash
d="$(mktemp -d)"
git show develop:docker-compose.yml > "$d/old.yml"
docker compose -p akfr-upgrade -f "$d/old.yml" --env-file .env.example create authentik_radius 2>&1 | tail -1
docker compose -p akfr-upgrade -f docker-compose.yml --env-file .env.example create authentik_radius 2>&1 | tail -2
docker network inspect akfr-upgrade_radius -f '{{(index .IPAM.Config 0).Subnet}}'
docker compose -p akfr-upgrade -f docker-compose.yml --env-file .env.example down --remove-orphans
rm -r "$d"
```

Expected: Der zweite `create` läuft ohne Fehler, `network inspect` zeigt `172.31.253.0/24`. `create` startet nichts, braucht also keine echten Secrets.

Scheitert der zweite `create` stattdessen mit einer Meldung zum Netz, diese Meldung wörtlich in den Troubleshooting-Text aus Step 8 übernehmen, als zweiten Satz des Absatzes „Upgrading …“.

- [ ] **Step 8: Doku**

`docs/troubleshooting.md`: den Absatz **Authentication stopped after the outpost alone was recreated** samt Codeblock und dem Absatz „If authentication stays down …“ ersetzen durch:

````markdown
**`AUTHENTIK_RADIUS_HOST must be a literal IPv4 address`** — the outpost is addressed by
its fixed IP on the `radius` network, never by name. A stopped container's name is
forwarded to the host's resolver, which can answer with an address outside the stack;
FreeRADIUS would then send inner requests there (issue #15). Keep
`AUTHENTIK_RADIUS_HOST: ${AUTHENTIK_RADIUS_IP}` from `docker-compose.yml`.

**Upgrading from a version without fixed addresses** — the `radius` network gets a fixed
subnet. A current Docker Compose recreates the network and the containers on the next
deploy by itself. If the deploy fails on the network instead, or the outpost does not come
up on `AUTHENTIK_RADIUS_IP`, remove the old network once and deploy again:

```bash
docker compose down
docker network rm <stack>_radius
```

In Portainer: stop the stack, delete the `<stack>_radius` network under **Networks**,
then deploy. Check the result with `docker network inspect <stack>_radius`.
````

`docs/monitoring.md`: die Tabellenzeile `| \`outpost address changed, restarting radiusd\` | … |` löschen.

`README.md`: im Abschnitt „Quickstart“ nach Punkt 4 einfügen:

```markdown
5. Leave `RADIUS_NET_SUBNET` at its default unless it collides with a network on the
   host. Both outposts get fixed addresses inside it; nothing depends on DNS.
```

- [ ] **Step 9: Commit**

```bash
git add freeradius/entrypoint.sh docker-compose.yml .env.example test/e2e/docker-compose.test.yml test/e2e/run.sh docs/troubleshooting.md docs/monitoring.md README.md
git commit -m "fix: Outpost über feste Adresse statt über den Namen ansprechen

Ein gestoppter Outpost-Container wird von Dockers DNS an den Resolver des
Hosts weitergereicht, der eine fremde Adresse liefern kann. Der Adress-
Watcher hätte radiusd dann darauf festgelegt. Das Netz bekommt ein festes
Subnetz, der Outpost eine feste Adresse, der Entrypoint verlangt eine IP.

Closes #15

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 2: PEAP-Schalter, Konfiguration und PEAP-Client in der e2e

Spec § 6.2–6.4. PEAP bleibt hier aus. Geprüft werden der Schalter, die Validierung und die FreeRADIUS-Konfiguration mit eingeschaltetem PEAP (`radiusd -XC`).

**Files:**
- Create: `freeradius/peap/ldap`, `freeradius/peap/inner-eap`, `freeradius/peap/linelog`, `freeradius/peap/eap-peap`, `freeradius/peap/peap-inner-tunnel`
- Modify: `freeradius/entrypoint.sh` (neue Funktion `write_peap_includes` nach `write_vlan_map`)
- Modify: `freeradius/radiusd.conf` (Block `modules`, Zeile `$INCLUDE sites-enabled/`)
- Modify: `freeradius/mods/eap` (vor der schließenden Klammer von `eap {`)
- Modify: `Dockerfile`
- Create: `test/e2e/client/peap.conf`
- Modify: `test/e2e/client/Dockerfile`, `test/e2e/client/auth.sh`, `test/e2e/run.sh`
- Modify: `.github/workflows/build.yml` (Job `validate`)

**Interfaces:**
- Consumes: `is_ipv4`, `auth`, `rejects` aus Task 1.
- Produces:
  - `auth.sh` versteht `AUTH_METHOD` (`ttls`|`peap`), `AUTH_USER`, `AUTH_PASSWORD`, `AUTH_TARGET` (Hostname, Standard `freeradius`), `AUTH_TIMEOUT` (Sekunden, Standard 30) und `AUTH_DUMP=1`.
  - Generierte Dateien `/run/radiusd/peap-modules.conf`, `peap-eap.conf` und `peap-site.conf`.
  - Log-Zeile `peap: no active WLAN user with a WiFi password: <user>`. Task 3 prüft sie, Task 7 dokumentiert sie.

- [ ] **Step 1: e2e-Test schreiben**

`test/e2e/client/peap.conf` (die eapol_test-Konfiguration aus der Probe, bestätigt gegen echtes authentik):

```
network={
	ssid="e2e"
	key_mgmt=WPA-EAP
	eap=PEAP
	identity="peapuser"
	anonymous_identity="anonymous"
	password="e2e-peap-pw"
	phase2="auth=MSCHAPV2"
}
```

`test/e2e/client/Dockerfile` nach `COPY ttls.conf /ttls.conf` ergänzen: `COPY peap.conf /peap.conf`.

`test/e2e/client/auth.sh` komplett ersetzen:

```sh
#!/bin/sh
# One EAP authentication attempt. Exit 0 on Access-Accept, non-zero otherwise.
#   AUTH_METHOD    ttls (default) or peap
#   AUTH_USER      inner identity (default testuser / peapuser)
#   AUTH_PASSWORD  inner password (default: the one in the profile)
#   AUTH_TARGET    host to authenticate against (default freeradius)
#   AUTH_TIMEOUT   seconds before eapol_test gives up (default 30)
#   AUTH_DUMP=1    print the full eapol_test log for the caller to read
set -u

target="${AUTH_TARGET:-freeradius}"
ip="$(getent hosts "$target" | awk '{print $1}' | head -1)"
if [ -z "$ip" ]; then
	echo "auth.sh: cannot resolve '$target'" >&2
	exit 2
fi

case "${AUTH_METHOD:-ttls}" in
	ttls) profile=/ttls.conf user="${AUTH_USER:-testuser}" ;;
	peap) profile=/peap.conf user="${AUTH_USER:-peapuser}" ;;
	*)
		echo "auth.sh: unknown AUTH_METHOD '${AUTH_METHOD}'" >&2
		exit 2
		;;
esac

# Test identities and passwords contain no sed metacharacters except the ones
# the injection test sends on purpose, so escape & / and \ for the replacement.
esc() { printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }
sed -e "s/^\([[:space:]]*\)identity=\".*\"/\1identity=\"$(esc "$user")\"/" "$profile" >/tmp/profile.conf
if [ -n "${AUTH_PASSWORD:-}" ]; then
	sed -i "s/^\([[:space:]]*\)password=\".*\"/\1password=\"$(esc "$AUTH_PASSWORD")\"/" /tmp/profile.conf
fi

# eapol_test -a requires an IP address, not a hostname.
eapol_test -c /tmp/profile.conf -a "$ip" -p 1812 -t "${AUTH_TIMEOUT:-30}" \
	-s "${RADIUS_SECRET:-e2e-uplink-secret-not-a-real-one}" -r0 >/tmp/eapol.log 2>&1
rc=$?
if [ "${AUTH_DUMP:-0}" = "1" ]; then cat /tmp/eapol.log; else tail -1 /tmp/eapol.log; fi
exit "$rc"
```

`test/e2e/run.sh`: In der Stufe `configuration the entrypoint must refuse` vor `echo "   ok"` einfügen:

```bash
peap_on=(PEAP_ENABLE=true LDAP_HOST=172.28.0.11
	"LDAP_BASE_DN=dc=ldap,dc=goauthentik,dc=io"
	"LDAP_BIND_DN=cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io"
	LDAP_BIND_PASSWORD=e2e-ldap-bind-not-a-real-one
	"LDAP_WLAN_GROUP_DN=cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io")
rejects "PEAP_ENABLE must be true or false" PEAP_ENABLE=yes
rejects "PEAP_ENABLE=true requires LDAP_BIND_PASSWORD" "${peap_on[@]}" LDAP_BIND_PASSWORD=
rejects "LDAP_HOST must be a literal IPv4 address" "${peap_on[@]}" LDAP_HOST=authentik_ldap
rejects "LDAP_WLAN_GROUP_DN may only contain" "${peap_on[@]}" "LDAP_WLAN_GROUP_DN=cn=wlan(x),ou=groups,dc=ldap,dc=goauthentik,dc=io"
rejects "LDAP_BASE_DN may only contain" "${peap_on[@]}" "LDAP_BASE_DN=dc=%{User-Name},dc=io"
rejects "LDAP_PORT must be a port number" "${peap_on[@]}" LDAP_PORT=3389x
```

`-e VAR=value` mehrfach: Bei `docker compose run` gewinnt der letzte Wert. Deshalb steht die Abweichung jeweils hinter `${peap_on[@]}`.

Vor der Stufe `container healthcheck` eine neue Stufe:

```bash
echo "== PEAP switched off =="
# A dedicated container with PEAP_ENABLE=false and no LDAP variables at all:
# PEAP must be refused, EAP-TTLS must work as before (spec 8.1).
"${COMPOSE[@]}" run -d --no-deps --name akfr-e2e-nopeap \
	-e PEAP_ENABLE=false -e LDAP_HOST= -e LDAP_BASE_DN= -e LDAP_BIND_DN= \
	-e LDAP_BIND_PASSWORD= -e LDAP_WLAN_GROUP_DN= freeradius >/dev/null
deadline=$(( $(date +%s) + 60 ))
until auth -e AUTH_TARGET=akfr-e2e-nopeap; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "EAP-TTLS failed against the container with PEAP switched off"
	sleep 3
done
if auth -e AUTH_TARGET=akfr-e2e-nopeap -e AUTH_METHOD=peap; then
	fail "PEAP succeeded with PEAP_ENABLE=false"
fi
docker rm -f akfr-e2e-nopeap >/dev/null
echo "   ok"
```

- [ ] **Step 2: Test laufen lassen, er muss scheitern**

Run: `./test/e2e/run.sh`
Expected: FAIL `freeradius started with PEAP_ENABLE=yes; expected it to refuse: PEAP_ENABLE must be true or false`.

- [ ] **Step 3: PEAP-Konfigurationsdateien anlegen**

`freeradius/peap/ldap`:

```
#  The authentik LDAP outpost, for PEAP-MSCHAPv2 (issue #14). Included only
#  when PEAP_ENABLE=true; see write_peap_includes in entrypoint.sh.
ldap {
	server = "$ENV{LDAP_HOST}"
	port = "$ENV{LDAP_PORT}"
	identity = "$ENV{LDAP_BIND_DN}"
	password = "$ENV{LDAP_BIND_PASSWORD}"
	base_dn = "$ENV{LDAP_BASE_DN}"

	#  32 hex characters. The pap call in peap-inner-tunnel turns them into
	#  the 16 bytes mschap expects; without it mschap rejects every password.
	update {
		control:NT-Password := 'wifi-password-nthash'
	}

	#  One filter decides everything: active, in the WLAN group, has a WiFi
	#  password. rlm_ldap escapes User-Name here; the group DN is inserted at
	#  parse time and is restricted to safe characters by entrypoint.sh.
	user {
		base_dn = "${..base_dn}"
		filter = "(&(cn=%{User-Name})(ak-active=TRUE)(memberOf=$ENV{LDAP_WLAN_GROUP_DN})(wifi-password-nthash=*))"
	}

	options {
		chase_referrals = no
		net_timeout = 3
		timeout = 3
		res_timeout = 3
	}

	#  start = 0: radiusd must come up, and keep serving EAP-TTLS, while the
	#  LDAP outpost is down. The pool reconnects on its own.
	pool {
		start = 0
		min = 0
		max = 8
		idle_timeout = 60
		lifetime = 300
	}
}
```

`freeradius/peap/inner-eap`:

```
#  EAP inside the PEAP tunnel: MSCHAPv2 only.
eap inner-eap {
	default_eap_type = mschapv2
	timer_expire = 60
	max_sessions = ${max_requests}
	mschapv2 {
	}
}
```

`freeradius/peap/linelog`:

```
#  The log line for a PEAP login the directory refused. Without it a
#  deactivated user and a typo look the same in the log.
linelog peap_log_notfound {
	filename = /dev/stdout
	format = "peap: no active WLAN user with a WiFi password: %{User-Name}"
}
```

`freeradius/peap/eap-peap`:

```
#  Pulled into the eap module by entrypoint.sh when PEAP_ENABLE=true.
peap {
	tls = tls-common
	default_eap_type = mschapv2
	#  Nothing from inside the tunnel reaches the access point: no
	#  MS-CHAP2-Success, no attribute an inner module might add.
	copy_request_to_tunnel = no
	use_tunneled_reply = no
	proxy_tunneled_request_as_eap = no
	virtual_server = "peap-inner-tunnel"
}
```

`freeradius/peap/peap-inner-tunnel`:

```
#  PEAP-MSCHAPv2: the NT hash comes from authentik via the LDAP outpost.
#  Verified against authentik 2026.8.3 (spec 6.4).
server peap-inner-tunnel {
	authorize {
		#  The EAP-Identity round needs nothing else.
		inner-eap {
			ok = return
		}
		#  notfound: inactive, not in the WLAN group, or no WiFi password.
		#  fail (LDAP unreachable) already ends in a reject.
		ldap
		if (notfound) {
			peap_log_notfound
			reject
		}
		pap
	}

	authenticate {
		#  The instance name is the Auth-Type; "Auth-Type eap" makes radiusd
		#  refuse to start.
		Auth-Type inner-eap {
			inner-eap
		}
		#  eap_mschapv2 calls "Auth-Type mschap", which only a bare mschap
		#  creates. "Auth-Type MS-CHAP" alone rejects every password.
		mschap
	}
}
```

- [ ] **Step 4: Include-Haken setzen**

`freeradius/radiusd.conf`, Block `modules`:

```
modules {
	$INCLUDE mods-enabled/
	#  ldap and inner-eap for PEAP, or nothing; written by entrypoint.sh.
	$-INCLUDE ${run_dir}/peap-modules.conf
}
```

Direkt nach `$INCLUDE sites-enabled/`:

```
#  The PEAP inner server, or nothing; written by entrypoint.sh.
$-INCLUDE ${run_dir}/peap-site.conf
```

`freeradius/mods/eap`: vor der letzten schließenden `}` des `eap {`-Blocks (nach dem `ttls { … }`-Block):

```
	#  The peap {} block, or nothing; written by entrypoint.sh.
	$-INCLUDE ${run_dir}/peap-eap.conf
```

`Dockerfile`: nach `COPY freeradius/sites/status …` einfügen:

```dockerfile
COPY freeradius/peap/ /etc/raddb/peap/
```

`mschap` und `pap` liegen im Basis-Image schon in `mods-enabled/`. Deshalb bindet `peap-modules.conf` nur `ldap`, `inner-eap` und `linelog` ein. So steht es auch in der Spec, § 6.3.

- [ ] **Step 5: `write_peap_includes` im Entrypoint**

In `freeradius/entrypoint.sh` direkt nach dem Block aus Task 1 einfügen, also nach dem `fi` der `OUTPOST_RESOLVE_INTERVAL`-Warnung. Die Funktion braucht `is_ipv4`, das dort definiert ist. Nach der Funktion steht ihr Aufruf: eine Zeile `write_peap_includes`.

```sh
# PEAP_ENABLE=true adds PEAP-MSCHAPv2 against the authentik LDAP outpost
# (issue #14). The modules live in /etc/raddb/peap/, outside mods-enabled/,
# so with PEAP off ldap is never instantiated; these includes are the switch.
write_peap_includes() {
	modules=/run/radiusd/peap-modules.conf
	eap=/run/radiusd/peap-eap.conf
	site=/run/radiusd/peap-site.conf
	case "${PEAP_ENABLE:-false}" in
		false)
			: > "$modules"
			: > "$eap"
			: > "$site"
			return 0
			;;
		true) ;;
		*) die "PEAP_ENABLE must be true or false (got '${PEAP_ENABLE}')" ;;
	esac

	for var in LDAP_HOST LDAP_BASE_DN LDAP_BIND_DN LDAP_BIND_PASSWORD LDAP_WLAN_GROUP_DN; do
		eval "value=\${$var:-}"
		[ -n "$value" ] || die "PEAP_ENABLE=true requires $var"
	done
	is_ipv4 "$LDAP_HOST" \
		|| die "LDAP_HOST must be a literal IPv4 address (got '$LDAP_HOST') - give the LDAP outpost a fixed address"

	# The DNs go into the configuration and the LDAP filter at parse time,
	# before rlm_ldap escapes anything, so only harmless characters pass.
	for var in LDAP_BASE_DN LDAP_BIND_DN LDAP_WLAN_GROUP_DN; do
		eval "value=\${$var}"
		case "$value" in
			*'
'*) die "$var must be a single line" ;;
		esac
		printf '%s\n' "$value" | grep -qxE '[A-Za-z0-9=,._ -]{1,256}' \
			|| die "$var may only contain A-Z a-z 0-9 = , . _ - and spaces (got '$value')"
	done

	LDAP_PORT="${LDAP_PORT:-3389}"
	case "$LDAP_PORT" in
		''|*[!0-9]*) die "LDAP_PORT must be a port number (got '$LDAP_PORT')" ;;
	esac
	export LDAP_PORT

	printf '$INCLUDE /etc/raddb/peap/ldap\n$INCLUDE /etc/raddb/peap/inner-eap\n$INCLUDE /etc/raddb/peap/linelog\n' > "$modules"
	printf '$INCLUDE /etc/raddb/peap/eap-peap\n' > "$eap"
	printf '$INCLUDE /etc/raddb/peap/peap-inner-tunnel\n' > "$site"
	echo "entrypoint: PEAP-MSCHAPv2 enabled, LDAP outpost at $LDAP_HOST:$LDAP_PORT" >&2
}
```

`printf '$INCLUDE …'` löst SC2016 aus, weil `$` in einfachen Anführungszeichen steht. Das ist hier gewollt; die Zeile darüber bekommt `# shellcheck disable=SC2016 # literal FreeRADIUS directive`.

- [ ] **Step 6: Konfiguration mit PEAP prüfen**

Die Zertifikate aus `test/e2e/certs/` nutzen; der e2e-Lauf aus Task 1 hat sie erzeugt.

```bash
docker build -q -t akfr:local .
MSYS_NO_PATHCONV=1 docker run --rm   -v "$(cygpath -w "$PWD/test/e2e/certs" 2>/dev/null || echo "$PWD/test/e2e/certs"):/certs:ro"   -e RADIUS_CLIENT_NET=10.0.0.0/8 -e RADIUS_SECRET=0123456789abcdef0   -e AUTHENTIK_RADIUS_HOST=127.0.0.1 -e AUTHENTIK_RADIUS_SECRET=0123456789abcdef0   -e TLS_CERT_PATH=/certs/server.crt -e TLS_KEY_PATH=/certs/server.key   -e PEAP_ENABLE=true -e LDAP_HOST=127.0.0.1 -e LDAP_BASE_DN=dc=ldap,dc=goauthentik,dc=io   -e LDAP_BIND_DN=cn=svc,ou=users,dc=ldap,dc=goauthentik,dc=io -e LDAP_BIND_PASSWORD=x   -e LDAP_WLAN_GROUP_DN=cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io   akfr:local -XC 2>&1 | grep -E 'peap-inner-tunnel|Configuration appears|rror' | head
```

Expected: Zeilen mit `peap-inner-tunnel` und `Configuration appears to be OK`, keine Zeile mit `Error`.

Vorab geprüft: Der Entrypoint reicht `-XC` an radiusd durch, und `radiusd -f -l stdout -d /etc/raddb -XC` endet mit Exit 0. `start = 0` im LDAP-Pool sorgt dafür, dass `-XC` keinen LDAP-Server braucht.

Dasselbe mit `-e PEAP_ENABLE=false` und ohne die `LDAP_*`-Variablen: `Configuration appears to be OK`, und `peap-inner-tunnel` kommt nicht vor.

- [ ] **Step 7: e2e laufen lassen, er muss bestehen**

Run: `./test/e2e/run.sh`
Expected: `PASS`. Die Stufe `PEAP switched off` meldet ok.

- [ ] **Step 8: CI: Konfiguration auch mit PEAP prüfen**

`.github/workflows/build.yml`, Job `validate`, nach dem Schritt „Check the FreeRADIUS configuration“:

```yaml
      - name: Check the FreeRADIUS configuration with PEAP enabled
        run: |
          #  Through the entrypoint this time: it validates the PEAP variables
          #  and writes the include files the configuration pulls in.
          set -euo pipefail
          docker run --rm \
            -v "$PWD/cert.pem:/certs/cert.pem:ro" \
            -v "$PWD/key.pem:/certs/key.pem:ro" \
            -e RADIUS_CLIENT_NET=10.0.0.0/8 \
            -e RADIUS_SECRET='se/cret&with\weird$chars' \
            -e AUTHENTIK_RADIUS_HOST=127.0.0.1 \
            -e AUTHENTIK_RADIUS_SECRET='an/other&secret-for-ci' \
            -e TLS_CERT_PATH=/certs/cert.pem \
            -e TLS_KEY_PATH=/certs/key.pem \
            -e PEAP_ENABLE=true \
            -e LDAP_HOST=127.0.0.1 \
            -e LDAP_BASE_DN=dc=ldap,dc=goauthentik,dc=io \
            -e LDAP_BIND_DN=cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io \
            -e LDAP_BIND_PASSWORD='tok/en&with\weird$chars' \
            -e LDAP_WLAN_GROUP_DN=cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io \
            akfr:ci -XC 2>&1 | tee radiusd-peap.log
          grep -q 'Configuration appears to be OK' radiusd-peap.log
          grep -q 'peap-inner-tunnel' radiusd-peap.log
```

- [ ] **Step 9: Lint**

Run: `shellcheck freeradius/entrypoint.sh freeradius/healthcheck.sh test/e2e/client/auth.sh test/e2e/run.sh`
Expected: keine Ausgabe.

- [ ] **Step 10: Commit**

```bash
git add freeradius/peap freeradius/entrypoint.sh freeradius/radiusd.conf freeradius/mods/eap Dockerfile test/e2e/client test/e2e/run.sh .github/workflows/build.yml
git commit -m "feat: PEAP-MSCHAPv2 per PEAP_ENABLE zuschaltbar

Eigener innerer Virtual Server, ldap-Modul gegen den authentik-LDAP-
Outpost, Einbindung über generierte Include-Dateien. Standard bleibt aus.

Refs #14

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 3: LDAP-Stand-in und PEAP-Stufen in der e2e

Spec § 8.1. PEAP läuft jetzt im Haupt-Container der e2e.

**Files:**
- Create: `test/e2e/ldap/Dockerfile`, `test/e2e/ldap/akfr.schema`, `test/e2e/ldap/slapd.conf`, `test/e2e/ldap/seed.ldif`
- Modify: `test/e2e/docker-compose.test.yml`, `test/e2e/run.sh`

**Interfaces:**
- Consumes: `auth`, `service_ip`, `started_at` aus Task 1; `AUTH_METHOD`, `AUTH_USER`, `AUTH_PASSWORD` und `AUTH_DUMP` aus Task 2; die Log-Zeile `peap: no active WLAN user with a WiFi password: <user>` aus Task 2.
- Produces: Dienst `authentik_ldap` (Stand-in, `172.28.0.11`) in der e2e-Compose-Datei. Nutzer:
  - `peapuser`: aktiv, in der Gruppe, Hash von `e2e-peap-pw` = `3CBA95EBEBA7DC7C85D03AFC1841D753`
  - `peapinactive`, `peapnogroup`, `peapnohash`: je eine Bedingung verletzt
  - Servicekonto `cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io` / `e2e-ldap-bind-not-a-real-one`

- [ ] **Step 1: e2e-Stufen schreiben**

`test/e2e/run.sh`:
- `up -d authentik_radius freeradius` wird `up -d authentik_radius authentik_ldap freeradius`.
- Vor der Stufe `PEAP switched off` einfügen:

```bash
peap() { auth -e AUTH_METHOD=peap -e AUTH_USER="$1" -e AUTH_PASSWORD="$2"; }

echo "== PEAP-MSCHAPv2 against the LDAP outpost =="
peap peapuser e2e-peap-pw || fail "PEAP with the right WiFi password was rejected"
if peap peapuser wrong-password; then fail "PEAP accepted a wrong password"; fi
for u in peapinactive peapnogroup peapnohash; do
	if peap "$u" e2e-peap-pw; then fail "PEAP accepted $u, who must be refused"; fi
done
"${COMPOSE[@]}" logs freeradius 2>&1 \
	| grep -q 'peap: no active WLAN user with a WiFi password: peapinactive' \
	|| fail "no log line for the refused PEAP login of peapinactive"
# User-Name goes into an LDAP filter; metacharacters must not widen it.
for u in '*' 'peapuser)(cn=*' 'peap*'; do
	if peap "$u" e2e-peap-pw; then fail "PEAP accepted the user name '$u'"; fi
done
echo "   ok"

echo "== nothing from inside the PEAP tunnel reaches the access point =="
accept="$("${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_METHOD=peap -e AUTH_DUMP=1 client 2>/dev/null \
	| sed -n '/code=2 (Access-Accept)/,/^[^ ]/p')"
[ -n "$accept" ] || fail "no Access-Accept for peapuser"
# Positive control: the MPPE keys (Microsoft vendor 311 = 0x137, type 16/17)
# must be there, or the pattern below proves nothing.
printf '%s\n' "$accept" | grep -qi 'Value: 0000013710' \
	|| fail "MS-MPPE-Send-Key missing from the outer Access-Accept"
# MS-CHAP2-Success is vendor 311 type 26 (0x1a). It belongs inside the tunnel.
if printf '%s\n' "$accept" | grep -qi 'Value: 000001371a'; then
	fail "MS-CHAP2-Success from inside the tunnel leaked into the outer Access-Accept"
fi
echo "   ok"

echo "== PEAP while the LDAP outpost is down =="
"${COMPOSE[@]}" stop authentik_ldap >/dev/null
start=$(date +%s)
if peap peapuser e2e-peap-pw; then fail "PEAP succeeded with the LDAP outpost stopped"; fi
took=$(( $(date +%s) - start ))
[ "$took" -le 15 ] || fail "PEAP took ${took}s to fail with the LDAP outpost down; it must fail fast"
auth || fail "EAP-TTLS failed while only the LDAP outpost was down"
echo "   ok (PEAP refused in ${took}s, EAP-TTLS unaffected)"

echo "== radiusd restarted while the LDAP outpost is down =="
"${COMPOSE[@]}" restart freeradius >/dev/null
deadline=$(( $(date +%s) + 60 ))
until auth; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "radiusd did not come back without the LDAP outpost"
	sleep 3
done
if peap peapuser e2e-peap-pw; then fail "PEAP succeeded with the LDAP outpost stopped"; fi
echo "   ok"

echo "== LDAP outpost back, no radiusd restart =="
before="$(started_at freeradius)"
"${COMPOSE[@]}" start authentik_ldap >/dev/null
deadline=$(( $(date +%s) + 60 ))
until peap peapuser e2e-peap-pw; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "PEAP did not recover after the LDAP outpost came back"
	sleep 3
done
[ "$(started_at freeradius)" = "$before" ] || fail "radiusd restarted to reconnect to LDAP; it must not"
echo "   ok"

echo "== LDAP outpost recreated keeps its address =="
"${COMPOSE[@]}" rm -sf authentik_ldap >/dev/null 2>&1
"${COMPOSE[@]}" up -d --no-deps authentik_ldap >/dev/null 2>&1
ip="$(service_ip authentik_ldap)"
[ "$ip" = 172.28.0.11 ] || fail "the LDAP outpost came back on '$ip', not on its fixed 172.28.0.11"
deadline=$(( $(date +%s) + 60 ))
until peap peapuser e2e-peap-pw; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "PEAP did not recover after the LDAP outpost was recreated"
	sleep 3
done
[ "$(started_at freeradius)" = "$before" ] || fail "radiusd restarted after the LDAP outpost was recreated"
echo "   ok"
```

Die Stufe `radiusd restarted …` startet den Container neu. Die `healthcheck`-Stufe am Ende wartet schon auf ein Ergebnis außer `starting`.

`test/e2e/docker-compose.test.yml`: Dienst nach `authentik_radius` einfügen:

```yaml
  authentik_ldap:
    # Stand-in for the authentik LDAP outpost: same DNs, same attribute names.
    build: ./ldap
    networks:
      e2e:
        ipv4_address: 172.28.0.11
```

In `freeradius.environment` ergänzen (kein `depends_on` auf `authentik_ldap`, spec § 6.1):

```yaml
      PEAP_ENABLE: "true"
      LDAP_HOST: 172.28.0.11
      LDAP_BASE_DN: dc=ldap,dc=goauthentik,dc=io
      LDAP_BIND_DN: cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io
      LDAP_BIND_PASSWORD: e2e-ldap-bind-not-a-real-one
      LDAP_WLAN_GROUP_DN: cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io
```

- [ ] **Step 2: Test laufen lassen, er muss scheitern**

Run: `./test/e2e/run.sh`
Expected: Abbruch beim Build, weil `test/e2e/ldap` fehlt (`unable to prepare context` / `path … not found`).

- [ ] **Step 3: Stand-in anlegen** (vorab gegen den Spec-Filter geprüft: nur `peapuser` trifft, anonym kommt nichts)

`test/e2e/ldap/akfr.schema`:

```
# Stand-in schema for the attributes the authentik LDAP outpost exposes.
# OIDs under 1.3.6.1.4.1.32473, the documentation arc from RFC 5612.
attributetype ( 1.3.6.1.4.1.32473.1.1.1 NAME 'ak-active'
	EQUALITY caseIgnoreMatch
	SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
attributetype ( 1.3.6.1.4.1.32473.1.1.2 NAME 'wifi-password-nthash'
	EQUALITY caseIgnoreMatch
	SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
attributetype ( 1.3.6.1.4.1.32473.1.1.3 NAME 'memberOf'
	EQUALITY distinguishedNameMatch
	SYNTAX 1.3.6.1.4.1.1466.115.121.1.12 )
objectclass ( 1.3.6.1.4.1.32473.1.2.1 NAME 'akUser' SUP top AUXILIARY
	MAY ( ak-active $ wifi-password-nthash $ memberOf ) )
```

`test/e2e/ldap/slapd.conf`:

```
include /etc/openldap/schema/core.schema
include /etc/openldap/schema/akfr.schema
pidfile /run/openldap/slapd.pid
modulepath /usr/lib/openldap
moduleload back_mdb.so
database mdb
maxsize 10485760
suffix "dc=ldap,dc=goauthentik,dc=io"
rootdn "cn=admin,dc=ldap,dc=goauthentik,dc=io"
directory /var/lib/openldap/openldap-data
# Like the real outpost: only the service account may search.
access to attrs=userPassword by anonymous auth by * none
access to * by dn.exact="cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io" read by * none
```

`test/e2e/ldap/seed.ldif`. Jeder Eintrag endet mit einer Leerzeile, die Datei mit einem Zeilenumbruch.

```
dn: dc=ldap,dc=goauthentik,dc=io
objectClass: dcObject
objectClass: organization
dc: ldap
o: e2e

dn: ou=users,dc=ldap,dc=goauthentik,dc=io
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=ldap,dc=goauthentik,dc=io
objectClass: organizationalUnit
ou: groups

dn: cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io
objectClass: person
cn: svc-wlan-ldap
sn: svc
userPassword: e2e-ldap-bind-not-a-real-one

dn: cn=peapuser,ou=users,dc=ldap,dc=goauthentik,dc=io
objectClass: person
objectClass: akUser
cn: peapuser
sn: peapuser
ak-active: TRUE
memberOf: cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io
wifi-password-nthash: 3CBA95EBEBA7DC7C85D03AFC1841D753

dn: cn=peapinactive,ou=users,dc=ldap,dc=goauthentik,dc=io
objectClass: person
objectClass: akUser
cn: peapinactive
sn: peapinactive
ak-active: FALSE
memberOf: cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io
wifi-password-nthash: 3CBA95EBEBA7DC7C85D03AFC1841D753

dn: cn=peapnogroup,ou=users,dc=ldap,dc=goauthentik,dc=io
objectClass: person
objectClass: akUser
cn: peapnogroup
sn: peapnogroup
ak-active: TRUE
wifi-password-nthash: 3CBA95EBEBA7DC7C85D03AFC1841D753

dn: cn=peapnohash,ou=users,dc=ldap,dc=goauthentik,dc=io
objectClass: person
objectClass: akUser
cn: peapnohash
sn: peapnohash
ak-active: TRUE
memberOf: cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io

```

`test/e2e/ldap/Dockerfile`:

```dockerfile
# Stand-in for the authentik LDAP outpost (issue #14): the DNs, the attribute
# names and the "only the service account may search" rule of the real one.
FROM alpine:3.21
RUN apk add --no-cache openldap openldap-back-mdb
COPY akfr.schema /etc/openldap/schema/akfr.schema
COPY slapd.conf /etc/openldap/slapd.conf
COPY seed.ldif /tmp/seed.ldif
RUN mkdir -p /run/openldap /var/lib/openldap/openldap-data \
 && slapadd -f /etc/openldap/slapd.conf -l /tmp/seed.ldif \
 && rm /tmp/seed.ldif
ENTRYPOINT ["/usr/sbin/slapd", "-d", "0", "-f", "/etc/openldap/slapd.conf", "-h", "ldap://0.0.0.0:3389/"]
```

Der CI-Lint prüft nur das Haupt-`Dockerfile` mit hadolint; dieser Stand-in folgt dem Stil von `test/e2e/backend/Dockerfile`.

- [ ] **Step 4: e2e laufen lassen, er muss bestehen**

Run: `./test/e2e/run.sh`
Expected: `PASS`.

Scheitert die Stufe mit der Log-Zeile, weil `linelog` nicht nach `/dev/stdout` schreiben kann:
1. Mit `docker compose -f test/e2e/docker-compose.test.yml logs freeradius | grep -i linelog` die Fehlermeldung holen.
2. Auf diese Ausweichlösung umstellen: In `peap-inner-tunnel` `peap_log_notfound` ersetzen durch `update request { &Module-Failure-Message := "peap: no active WLAN user with a WiFi password" }`. In `freeradius/radiusd.conf`, Block `log`, `auth = yes` setzen. In `peap-modules.conf` `linelog` nicht mehr einbinden, `freeradius/peap/linelog` löschen.
3. Den grep in der Stufe auf `Login incorrect.*peap: no active WLAN user with a WiFi password.*peapinactive` ändern.

Die Abweichung im Commit-Text nennen.

- [ ] **Step 5: Gegenprobe für den Reply-Test**

Temporär in `freeradius/peap/eap-peap` `use_tunneled_reply = no` auf `yes` setzen und `./test/e2e/run.sh` laufen lassen.
Expected: FAIL `MS-CHAP2-Success from inside the tunnel leaked into the outer Access-Accept`.

Danach zurück auf `no` und `git diff freeradius/peap/eap-peap` prüfen: keine Änderung übrig.

Schlägt die Gegenprobe nicht an, stimmt das Muster nicht. Dann mit `AUTH_DUMP=1` die echte Darstellung der Vendor-Attribute in der eapol_test-Ausgabe ansehen und beide Muster anpassen.

- [ ] **Step 6: Commit**

```bash
git add test/e2e/ldap test/e2e/docker-compose.test.yml test/e2e/run.sh
git commit -m "test: PEAP gegen ein LDAP-Stand-in in der e2e

OpenLDAP mit den Attributnamen des authentik-Outposts. Geprüft werden
richtiges und falsches Passwort, die drei Sperrgründe, Sonderzeichen im
Benutzernamen, Ausfall und Rückkehr von LDAP ohne Neustart von radiusd
und dass nichts aus dem inneren Tunnel nach außen gelangt.

Refs #14

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 4: Produktions-Compose für PEAP

Spec § 6.1, § 6.2.

**Files:**
- Create: `docker-compose.peap.yml`
- Modify: `.env.example`, `.github/workflows/build.yml` (Job `lint`)

**Interfaces:**
- Consumes: Netz `radius` mit festem Subnetz aus Task 1; Variablen `PEAP_ENABLE`, `LDAP_*` aus Task 2.
- Produces: Variablen `AUTHENTIK_LDAP_TOKEN`, `AUTHENTIK_LDAP_IP`, `LDAP_BASE_DN`, `LDAP_BIND_DN`, `LDAP_BIND_PASSWORD`, `LDAP_WLAN_GROUP_DN`; Task 7 dokumentiert sie.

- [ ] **Step 1: Prüfung zuerst**

`.github/workflows/build.yml`, Job `lint`, neuer Schritt nach „Lint the shell scripts“:

```yaml
      - name: Check the Compose files
        run: |
          set -euo pipefail
          docker compose -f docker-compose.yml --env-file .env.example config >/dev/null
          docker compose -f docker-compose.yml -f docker-compose.peap.yml --env-file .env.example config >/dev/null
          #  Without the LDAP token the PEAP file must refuse to render.
          grep -v '^AUTHENTIK_LDAP_TOKEN=' .env.example > /tmp/no-token.env
          if docker compose -f docker-compose.yml -f docker-compose.peap.yml --env-file /tmp/no-token.env config >/dev/null 2>&1; then
            echo "docker-compose.peap.yml rendered without AUTHENTIK_LDAP_TOKEN" >&2
            exit 1
          fi
```

Lokal dasselbe ausführen.
Expected: Die zweite Zeile scheitert, weil `docker-compose.peap.yml` fehlt.

- [ ] **Step 2: `docker-compose.peap.yml` anlegen**

```yaml
#  PEAP-MSCHAPv2 with a WiFi password generated in authentik (issue #14).
#
#  Add this file next to docker-compose.yml -- in Portainer as an additional
#  path of the Git stack. Without it the stack serves EAP-TTLS only.
#
#  FreeRADIUS does not wait for this outpost: EAP-TTLS must work while LDAP is
#  down, so a PEAP login right after a deploy fails until the outpost is ready.

services:
  authentik_ldap:
    image: ghcr.io/goauthentik/ldap:${AUTHENTIK_VERSION:?set AUTHENTIK_VERSION to match your authentik server}
    restart: unless-stopped
    environment:
      AUTHENTIK_HOST: ${AUTHENTIK_HOST:?set AUTHENTIK_HOST}
      AUTHENTIK_TOKEN: ${AUTHENTIK_LDAP_TOKEN:?set AUTHENTIK_LDAP_TOKEN to the LDAP outpost token}
      AUTHENTIK_INSECURE: ${AUTHENTIK_INSECURE:-false}
    #  No published port: only FreeRADIUS talks to it, over the radius network.
    networks:
      radius:
        ipv4_address: ${AUTHENTIK_LDAP_IP:-172.31.253.11}
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  freeradius:
    environment:
      PEAP_ENABLE: "true"
      LDAP_HOST: ${AUTHENTIK_LDAP_IP:-172.31.253.11}
      LDAP_BASE_DN: ${LDAP_BASE_DN:?set LDAP_BASE_DN to the base DN of the wlan-ldap provider}
      LDAP_BIND_DN: ${LDAP_BIND_DN:?set LDAP_BIND_DN to the DN of svc-wlan-ldap}
      LDAP_BIND_PASSWORD: ${LDAP_BIND_PASSWORD:?set LDAP_BIND_PASSWORD to the token of svc-wlan-ldap}
      LDAP_WLAN_GROUP_DN: ${LDAP_WLAN_GROUP_DN:?set LDAP_WLAN_GROUP_DN to the DN of the WLAN group}
```

- [ ] **Step 3: `.env.example` ergänzen**

Unter `AUTHENTIK_RADIUS_IP=…` aus Task 1 die Zeile `AUTHENTIK_LDAP_IP=172.31.253.11` einfügen. Am Ende der Datei, vor `--- debugging`, diesen Block einfügen:

```sh
#  --- PEAP (docker-compose.peap.yml only) -----------------------------------
#  Token of the LDAP outpost "wlan-ldap" in authentik.
AUTHENTIK_LDAP_TOKEN=CHANGEME-ldap-outpost-token
#  Base DN of the wlan-ldap provider, and the DNs FreeRADIUS needs. Allowed
#  characters: A-Z a-z 0-9 = , . _ - and spaces.
LDAP_BASE_DN=dc=ldap,dc=goauthentik,dc=io
LDAP_BIND_DN=cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io
#  Token of the service account svc-wlan-ldap (Directory > Tokens).
LDAP_BIND_PASSWORD=CHANGEME-service-account-token
LDAP_WLAN_GROUP_DN=cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io
```

- [ ] **Step 4: Prüfung aus Step 1 erneut ausführen**

Expected: Beide `config`-Aufrufe laufen, der ohne Token scheitert erwartungsgemäß, Exit 0 insgesamt.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.peap.yml .env.example .github/workflows/build.yml
git commit -m "feat: Compose-Zusatzdatei für PEAP mit LDAP-Outpost

Refs #14

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 5: authentik-Blueprint mit Expressions und Unit-Tests

Spec § 5. Der Blueprint wird aus Quelldateien erzeugt, damit die Expressions testbar sind und es genau eine Quelle gibt.

**Files:**
- Create: `authentik/src/md4.py`, `authentik/src/wifi_password_generate.expr`, `authentik/src/wifi_password_save.expr`
- Create: `authentik/src/eff_short_wordlist_1.txt`, `authentik/src/wlan-passwort.yaml.in`
- Create: `authentik/build_blueprint.py`
- Create: `authentik/blueprints/wlan-passwort.yaml` (generiert, eingecheckt)
- Create: `test/authentik/test_expressions.py`
- Modify: `.github/workflows/build.yml` (neuer Job `blueprint`, `build.needs` ergänzen)

**Interfaces:**
- Produces:
  - `build_blueprint.py`:
    - `words() -> list[str]`
    - `expressions() -> tuple[str, str]` liefert `(generate, save)` als fertigen Python-Body.
    - `render() -> str`, `OUT: pathlib.Path`
    - CLI: ohne Argument schreibt es `OUT`; mit `--check` endet es mit Exit 1, wenn `OUT` veraltet ist.
  - Generate-Expression:
    - Kontext: `user`, `http_request` (darf `None` sein)
    - Rückgabe: Passphrase-String
    - Seiteneffekt: `http_request.session["wifi_password_pending"]`
  - Save-Expression:
    - Kontext: `request` (`.context["prompt_data"]`, `.http_request.session`, `.user`), `ak_message`, `ak_logger`
    - Rückgabe: `bool`

  Task 6 importiert die YAML-Datei.

- [ ] **Step 1: Tests schreiben**

`test/authentik/test_expressions.py`:

```python
"""Unit tests for the authentik expressions shipped in the WLAN blueprint.

They run the exact expression text build_blueprint.py puts into the
blueprint, wrapped in a function the way authentik evaluates it, against
small fakes of the objects authentik passes in. Standard library only.
"""
import contextlib
import pathlib
import sys
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2] / "authentik"
sys.path.insert(0, str(ROOT))
import build_blueprint  # noqa: E402


def compile_expression(code, params):
    body = "\n".join("    " + line for line in code.splitlines())
    namespace = {}
    exec(f"def _expression({', '.join(params)}):\n{body}\n", namespace)
    return namespace["_expression"]


GENERATE_SRC, SAVE_SRC = build_blueprint.expressions()
generate = compile_expression(GENERATE_SRC, ["user", "http_request"])
save = compile_expression(SAVE_SRC, ["request", "ak_message", "ak_logger"])
md4_ns = {}
exec((ROOT / "src" / "md4.py").read_text(encoding="utf-8"), md4_ns)
md4 = md4_ns["md4"]


def nt_hash(password):
    return md4(password.encode("utf-16-le")).hex().upper()


class FakeUser:
    def __init__(self, pk=1, attributes=None):
        self.pk = pk
        self.username = f"user{pk}"
        self.attributes = dict(attributes or {})
        self.saves = []

    def save(self, update_fields=None):
        self.saves.append(update_fields)


class FakeManager:
    def __init__(self, users, broken=False):
        self.users = users
        self.broken = broken

    def select_for_update(self):
        return self

    def get(self, pk):
        if self.broken:
            raise RuntimeError("database is gone")
        return self.users[pk]


def install_fakes(users, broken=False):
    db = types.ModuleType("django.db")
    db.transaction = types.SimpleNamespace(atomic=contextlib.nullcontext)
    models = types.ModuleType("authentik.core.models")
    models.User = types.SimpleNamespace(objects=FakeManager(users, broken))
    sys.modules.update({
        "django": types.ModuleType("django"),
        "django.db": db,
        "authentik": types.ModuleType("authentik"),
        "authentik.core": types.ModuleType("authentik.core"),
        "authentik.core.models": models,
    })


class Logger:
    def info(self, *args, **kwargs):
        pass

    warning = info


class Md4Test(unittest.TestCase):
    def test_rfc1320_vectors(self):
        self.assertEqual(md4(b"").hex(), "31d6cfe0d16ae931b73c59d7e0c089c0")
        self.assertEqual(md4(b"abc").hex(), "a448017aaf21d8525fc10ae87aa6729d")
        self.assertEqual(md4(b"message digest").hex(), "d9130a8164549fe818874806e1c7014b")
        self.assertEqual(
            md4(b"12345678901234567890123456789012345678901234567890123456789012345678901234567890").hex(),
            "e33b4ddc9c38f2199c3e7b164fcc0536",
        )

    def test_nt_hash_of_password(self):
        self.assertEqual(nt_hash("password"), "8846F7EAEE8FB117AD06BDD830B7586C")


class WordlistTest(unittest.TestCase):
    def test_eff_short_list_without_the_hyphenated_entry(self):
        words = build_blueprint.words()
        self.assertEqual(len(words), 1295)
        self.assertEqual(len(set(words)), 1295)
        self.assertNotIn("yo-yo", words)
        self.assertTrue(all(w.isalpha() and w.islower() and 3 <= len(w) <= 5 for w in words))


class GenerateTest(unittest.TestCase):
    def setUp(self):
        self.user = FakeUser()
        self.http = types.SimpleNamespace(session={})

    def test_six_words_from_the_list(self):
        words = set(build_blueprint.words())
        parts = generate(self.user, self.http).split("-")
        self.assertEqual(len(parts), 6)
        self.assertTrue(set(parts) <= words)

    def test_same_passphrase_until_saved(self):
        first = generate(self.user, self.http)
        self.assertEqual(generate(self.user, self.http), first)

    def test_new_passphrase_after_save_even_if_session_kept(self):
        first = generate(self.user, self.http)
        self.user.attributes["wifi-password-set-at"] = "2026-10-13T00:00:00+00:00"
        self.assertNotEqual(generate(self.user, self.http), first)

    def test_preview_without_request(self):
        self.assertEqual(generate(self.user, None), "")


class SaveTest(unittest.TestCase):
    def setUp(self):
        self.user = FakeUser()
        install_fakes({1: self.user})
        self.session = {"wifi_password_pending": {"pw": "acid-acorn-acre-acts-afar-affix", "base": ""}}
        self.messages = []

    def run_save(self, prompt_data):
        request = types.SimpleNamespace(
            context={"prompt_data": prompt_data},
            http_request=types.SimpleNamespace(session=self.session),
            user=self.user,
        )
        return save(request, self.messages.append, Logger())

    def test_saves_the_hash_of_the_shown_passphrase(self):
        ok = self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True})
        self.assertTrue(ok)
        self.assertEqual(self.user.attributes["wifi-password-nthash"], nt_hash("acid-acorn-acre-acts-afar-affix"))
        self.assertTrue(self.user.attributes["wifi-password-set-at"].endswith("+00:00"))
        self.assertEqual(self.user.saves, [["attributes"]])
        self.assertNotIn("wifi_password_pending", self.session)

    def test_keeps_other_attributes(self):
        self.user.attributes["settings"] = {"locale": "de"}
        self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True})
        self.assertEqual(self.user.attributes["settings"], {"locale": "de"})

    def test_refuses_a_value_that_is_not_the_pending_one(self):
        ok = self.run_save({"wifi_password": "attacker-chosen", "wifi_ack": True})
        self.assertFalse(ok)
        self.assertNotIn("wifi-password-nthash", self.user.attributes)
        self.assertTrue(self.messages)

    def test_requires_the_checkbox_to_be_exactly_true(self):
        for ack in (False, "true", "True", 1, None):
            with self.subTest(ack=ack):
                data = {"wifi_password": "acid-acorn-acre-acts-afar-affix"}
                if ack is not None:
                    data["wifi_ack"] = ack
                self.assertFalse(self.run_save(data))
                self.assertNotIn("wifi-password-nthash", self.user.attributes)

    def test_nothing_pending(self):
        self.session.clear()
        self.assertFalse(self.run_save({"wifi_password": "", "wifi_ack": True}))

    def test_database_error_writes_nothing(self):
        install_fakes({1: self.user}, broken=True)
        self.assertFalse(self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True}))
        self.assertNotIn("wifi-password-nthash", self.user.attributes)
        self.assertIn("wifi_password_pending", self.session)


class BlueprintTest(unittest.TestCase):
    def test_committed_blueprint_is_current(self):
        self.assertEqual(build_blueprint.OUT.read_text(encoding="utf-8"), build_blueprint.render())


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Test laufen lassen, er muss scheitern**

Run: `python3 -I -m unittest discover -s test/authentik -p 'test_*.py'`
Expected: FAIL mit `ModuleNotFoundError: No module named 'build_blueprint'`.

Der Test setzt `sys.path` selbst, deshalb funktioniert `-I`.

- [ ] **Step 3: Quellen anlegen**

`authentik/src/eff_short_wordlist_1.txt`: die Liste von `https://www.eff.org/files/2016/09/08/eff_short_wordlist_1.txt` herunterladen. Dann eine Kopfzeile davor setzen:

```
# EFF Short Wordlist 1, https://www.eff.org/dice -- CC BY 3.0 US,
# Electronic Frontier Foundation. Unchanged; build_blueprint.py skips yo-yo.
```

Die Liste unverändert lassen und auf LF normalisieren (`tr -d '\r'`). Prüfen: 1296 Datenzeilen.

`authentik/src/md4.py`: die Funktion aus der Probe; gegen RFC-1320-Vektoren geprüft.

```python
# MD4 (RFC 1320). authentik's Python links OpenSSL 3, which no longer offers
# MD4, and the NT hash MSCHAPv2 needs is MD4 over the UTF-16LE password.
import struct


def md4(data):
    def rol(v, s):
        v &= 0xFFFFFFFF
        return ((v << s) | (v >> (32 - s))) & 0xFFFFFFFF

    F = lambda x, y, z: (x & y) | (~x & z)  # noqa: E731
    G = lambda x, y, z: (x & y) | (x & z) | (y & z)  # noqa: E731
    H = lambda x, y, z: x ^ y ^ z  # noqa: E731
    msg = bytearray(data)
    bitlen = len(data) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    msg += struct.pack("<Q", bitlen)
    a, b, c, d = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476
    for off in range(0, len(msg), 64):
        X = struct.unpack("<16I", bytes(msg[off:off + 64]))
        A, B, C, D = a, b, c, d
        for i in (0, 4, 8, 12):
            A = rol(A + F(B, C, D) + X[i], 3)
            D = rol(D + F(A, B, C) + X[i + 1], 7)
            C = rol(C + F(D, A, B) + X[i + 2], 11)
            B = rol(B + F(C, D, A) + X[i + 3], 19)
        for i in (0, 1, 2, 3):
            A = rol(A + G(B, C, D) + X[i] + 0x5A827999, 3)
            D = rol(D + G(A, B, C) + X[i + 4] + 0x5A827999, 5)
            C = rol(C + G(D, A, B) + X[i + 8] + 0x5A827999, 9)
            B = rol(B + G(C, D, A) + X[i + 12] + 0x5A827999, 13)
        for i in (0, 2, 1, 3):
            A = rol(A + H(B, C, D) + X[i] + 0x6ED9EBA1, 3)
            D = rol(D + H(A, B, C) + X[i + 8] + 0x6ED9EBA1, 9)
            C = rol(C + H(D, A, B) + X[i + 4] + 0x6ED9EBA1, 11)
            B = rol(B + H(C, D, A) + X[i + 12] + 0x6ED9EBA1, 15)
        a, b, c, d = [(p + q) & 0xFFFFFFFF for p, q in ((a, A), (b, B), (c, C), (d, D))]
    return struct.pack("<4I", a, b, c, d)
```

`authentik/src/wifi_password_generate.expr`: Body der Initialwert-Expression. `WORDS` setzt der Generator davor.

```python
# Initial value of the read-only wifi_password field (spec 5.1). authentik
# evaluates it on every render AND again on submit, so the passphrase lives in
# the session: the same one until it is saved, then a new one. "base" is the
# user's wifi-password-set-at when it was made; once the save policy writes a
# new timestamp, the next visit gets a new passphrase even if clearing the
# session did not stick.
import secrets

if http_request is None:
    return ""
session = http_request.session
base = (user.attributes or {}).get("wifi-password-set-at", "")
pending = session.get("wifi_password_pending")
if not pending or pending.get("base") != base:
    pending = {"pw": "-".join(secrets.choice(WORDS) for _ in range(6)), "base": base}
    session["wifi_password_pending"] = pending
return pending["pw"]
```

`authentik/src/wifi_password_save.expr`: Body der Validierungs-Policy. `md4` setzt der Generator davor.

```python
# Validation policy of the wlan-passwort-anzeige prompt stage (spec 5.1).
# prompt_data holds the server-side value of the read-only field, never what
# the browser posted; it must still match the pending passphrase.
from datetime import datetime, timezone

from authentik.core.models import User
from django.db import transaction

data = request.context.get("prompt_data") or {}
if data.get("wifi_ack") is not True:
    ak_message("Bitte bestätige, dass du das Passwort notiert hast.")
    return False
password = data.get("wifi_password")
pending = request.http_request.session.get("wifi_password_pending") or {}
if not password or password != pending.get("pw") or not request.user.pk:
    ak_message("Das WLAN-Passwort ist abgelaufen. Bitte lade die Seite neu.")
    return False
try:
    with transaction.atomic():
        fresh = User.objects.select_for_update().get(pk=request.user.pk)
        fresh.attributes["wifi-password-nthash"] = md4(password.encode("utf-16-le")).hex().upper()
        fresh.attributes["wifi-password-set-at"] = datetime.now(timezone.utc).isoformat()
        fresh.save(update_fields=["attributes"])
except Exception as exc:
    ak_logger.warning("wifi password not saved", exc=repr(exc))
    ak_message("Das WLAN-Passwort konnte nicht gespeichert werden. Bitte versuche es erneut.")
    return False
request.http_request.session.pop("wifi_password_pending", None)
ak_logger.info("wifi password set", user=fresh.username)
return True
```

Zum Test `test_database_error_writes_nothing`: Die Exception kommt aus `get()`, also bevor ein Attribut gesetzt wird. Deshalb bleibt `self.user` unverändert.

- [ ] **Step 4: Blueprint-Vorlage**

`authentik/src/wlan-passwort.yaml.in`:

```yaml
# authentik blueprint for the WiFi password (authentik-freeradius, issue #14).
# GENERATED from authentik/src/ by authentik/build_blueprint.py -- edit the
# sources, then run: python3 authentik/build_blueprint.py
#
# Not covered here, see docs/authentik.md section 6: the service account
# svc-wlan-ldap, its search permission, and the LDAP outpost.
version: 1
metadata:
  name: authentik-freeradius WLAN-Passwort
  labels:
    blueprints.goauthentik.io/instantiate: "false"
context:
  wlan_group: wlan
  ldap_search_group: wlan-ldap-search
  ssid: WLAN
  radius_server_name: radius.example.com
  ldap_base_dn: dc=ldap,dc=goauthentik,dc=io
entries:
  # Groups are only created, never changed: an existing WLAN group keeps its
  # members and settings.
  - model: authentik_core.group
    state: created
    identifiers:
      name: !Context wlan_group
  - model: authentik_core.group
    state: created
    identifiers:
      name: !Context ldap_search_group

  # --- WiFi password flow (spec 5.1) --------------------------------------
  - model: authentik_policies_expression.expressionpolicy
    id: policy-save
    identifiers:
      name: wlan-passwort-speichern
    attrs:
      expression: |
@SAVE@
  - model: authentik_stages_prompt.prompt
    id: prompt-password
    identifiers:
      name: wlan-passwort-feld
    attrs:
      field_key: wifi_password
      label: Dein WLAN-Passwort
      type: text_read_only
      required: false
      order: 0
      initial_value_expression: true
      initial_value: |
@GENERATE@
  - model: authentik_stages_prompt.prompt
    id: prompt-info
    identifiers:
      name: wlan-passwort-info
    attrs:
      field_key: wifi_info
      label: So verbindest du dich
      type: static
      required: false
      order: 1
      initial_value: !Format
        - "WLAN: %s. Benutzername: dein authentik-Benutzername. Beim ersten Verbinden fragt das Gerät nach einem Zertifikat: bestätige es nur, wenn es auf %s lautet. Das Passwort wird nur jetzt angezeigt."
        - !Context ssid
        - !Context radius_server_name
  - model: authentik_stages_prompt.prompt
    id: prompt-ack
    identifiers:
      name: wlan-passwort-bestaetigung
    attrs:
      field_key: wifi_ack
      label: Ich habe das Passwort notiert. Mein bisheriges WLAN-Passwort wird damit ungültig.
      type: checkbox
      required: true
      order: 2
  - model: authentik_stages_prompt.promptstage
    id: stage-prompt
    identifiers:
      name: wlan-passwort-anzeige
    attrs:
      fields:
        - !KeyOf prompt-password
        - !KeyOf prompt-info
        - !KeyOf prompt-ack
      validation_policies:
        - !KeyOf policy-save
  - model: authentik_flows.flow
    id: flow-wlan
    identifiers:
      slug: wlan-passwort
    attrs:
      name: WLAN-Passwort
      title: WLAN-Passwort
      designation: stage_configuration
      authentication: require_authenticated
  - model: authentik_policies.policybinding
    identifiers:
      target: !KeyOf flow-wlan
      order: 0
    attrs:
      group: !Find [authentik_core.group, [name, !Context wlan_group]]
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf flow-wlan
      stage: !KeyOf stage-prompt
      order: 10

  # --- Portal tile (spec 5.4) ----------------------------------------------
  - model: authentik_core.application
    id: app-wlan
    identifiers:
      slug: wlan-zugang
    attrs:
      name: WLAN-Zugang
      meta_launch_url: /if/flow/wlan-passwort/
  - model: authentik_policies.policybinding
    identifiers:
      target: !KeyOf app-wlan
      order: 0
    attrs:
      group: !Find [authentik_core.group, [name, !Context wlan_group]]

  # --- LDAP for FreeRADIUS (spec 5.5) --------------------------------------
  - model: authentik_stages_identification.identificationstage
    id: ldap-ident
    identifiers:
      name: wlan-ldap-identification
    attrs:
      user_fields: [username]
  - model: authentik_stages_password.passwordstage
    id: ldap-password
    identifiers:
      name: wlan-ldap-password
    attrs:
      # The service account binds with its app-password token.
      backends:
        - authentik.core.auth.InbuiltBackend
        - authentik.core.auth.TokenBackend
  - model: authentik_stages_user_login.userloginstage
    id: ldap-login
    identifiers:
      name: wlan-ldap-login
  - model: authentik_flows.flow
    id: flow-ldap-bind
    identifiers:
      slug: wlan-ldap-bind
    attrs:
      name: WLAN LDAP bind
      title: WLAN LDAP bind
      designation: authentication
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf flow-ldap-bind
      stage: !KeyOf ldap-ident
      order: 10
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf flow-ldap-bind
      stage: !KeyOf ldap-password
      order: 20
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf flow-ldap-bind
      stage: !KeyOf ldap-login
      order: 30
  - model: authentik_providers_ldap.ldapprovider
    id: provider-ldap
    identifiers:
      name: wlan-ldap
    attrs:
      authorization_flow: !KeyOf flow-ldap-bind
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
      base_dn: !Context ldap_base_dn
      # direct: a deactivation or group change applies to the next login.
      search_mode: direct
      bind_mode: direct
  - model: authentik_core.application
    id: app-ldap
    identifiers:
      slug: wlan-ldap
    attrs:
      name: wlan-ldap
      provider: !KeyOf provider-ldap
  # Only members of this group may bind. Nobody is in it until the service
  # account is added; this provider hands out NT hashes.
  - model: authentik_policies.policybinding
    identifiers:
      target: !KeyOf app-ldap
      order: 0
    attrs:
      group: !Find [authentik_core.group, [name, !Context ldap_search_group]]
```

- [ ] **Step 5: Generator**

`authentik/build_blueprint.py`:

```python
#!/usr/bin/env python3
"""Render authentik/blueprints/wlan-passwort.yaml from authentik/src/.

    python3 authentik/build_blueprint.py          write the blueprint
    python3 authentik/build_blueprint.py --check  exit 1 if it is out of date
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src"
OUT = ROOT / "blueprints" / "wlan-passwort.yaml"
# The expressions sit in YAML block scalars under "attrs:"; eight spaces nests
# them below their key.
INDENT = " " * 8


def _read(name):
    return (SRC / name).read_text(encoding="utf-8")


def words():
    out = []
    for line in _read("eff_short_wordlist_1.txt").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        word = line.split()[-1]
        # The hyphen separates the words of a passphrase, so yo-yo is out.
        if word.isalpha() and word.islower():
            out.append(word)
    return out


def expressions():
    generate = "WORDS = " + repr(tuple(words())) + "\n" + _read("wifi_password_generate.expr")
    save = _read("md4.py") + "\n" + _read("wifi_password_save.expr")
    return generate, save


def _block(code):
    return "\n".join(INDENT + line if line.strip() else "" for line in code.rstrip("\n").splitlines())


def render():
    generate, save = expressions()
    template = _read("wlan-passwort.yaml.in")
    return template.replace("@GENERATE@", _block(generate)).replace("@SAVE@", _block(save))


def main(argv):
    text = render()
    if argv[1:] == ["--check"]:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print(f"{OUT} is out of date; run: python3 authentik/build_blueprint.py", file=sys.stderr)
            return 1
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 6: Blueprint erzeugen, Tests laufen lassen**

Run: `python3 -I authentik/build_blueprint.py && python3 -I -m unittest discover -s test/authentik -p 'test_*.py' -v`
Expected: alle Tests `ok`, insgesamt 14.

Run: `python3 -I authentik/build_blueprint.py --check; echo $?`
Expected: `0`

- [ ] **Step 7: CI-Job**

`.github/workflows/build.yml`, neuer Job nach `lint`:

```yaml
  blueprint:
    #  The authentik expressions: MD4, passphrase, save policy. And that the
    #  committed blueprint matches its sources.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Unit-test the expressions
        run: python3 -I -m unittest discover -s test/authentik -p 'test_*.py' -v
      - name: Check the blueprint is generated from its sources
        run: python3 -I authentik/build_blueprint.py --check
```

`build.needs` wird `[lint, validate, e2e, blueprint]`.

- [ ] **Step 8: Commit**

```bash
git add authentik test/authentik .github/workflows/build.yml
git commit -m "feat: authentik-Blueprint für das generierte WLAN-Passwort

Flow mit Prompt-Stage, Passphrase aus sechs EFF-Wörtern in der Session,
Validierungs-Policy speichert den NT-Hash. Dazu LDAP-Provider mit eigenem
Bind-Flow. Der Blueprint wird aus authentik/src/ erzeugt; Unit-Tests
prüfen MD4, Passphrase und Policy.

Refs #14

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 6: Integrationstest gegen echtes authentik

Spec § 8.3. Er läuft lokal und per `workflow_dispatch`, nicht bei jedem Push. Er belegt den Blueprint aus Task 5 gegen authentik 2026.8.3. Die Fehler, die er findet, behebt diese Aufgabe in `authentik/src/` und erzeugt den Blueprint neu.

**Files:**
- Create: `test/authentik/docker-compose.yml`, `test/authentik/run.sh`, `test/authentik/drive.py`
- Create: `.github/workflows/authentik-integration.yml`
- Modify: `test/e2e/client/Dockerfile` (Paket `openldap-clients`)
- Modify: `.gitignore` (`test/authentik/.state/`)
- Modify: `.github/workflows/build.yml` (Job `lint`: `test/authentik/run.sh` zur shellcheck-Liste)
- Modify (falls nötig): `authentik/src/*`, `authentik/blueprints/wlan-passwort.yaml`

**Interfaces:**
- Consumes:
  - `authentik/blueprints/wlan-passwort.yaml` (Task 5)
  - das FreeRADIUS-Image mit PEAP (Task 2)
  - den e2e-Client mit `AUTH_METHOD`, `AUTH_USER`, `AUTH_PASSWORD` und `AUTH_TARGET` (Task 2)
- Produces: `drive.py` mit diesen Unterbefehlen. Alle lesen und schreiben im Ordner `test/authentik/.state/`, Exit ≠ 0 bei Fehler.
  - `setup`: schreibt `it.env` mit `IT_LDAP_TOKEN` und `IT_LDAP_BIND_PASSWORD`.
  - `flow <user> <pw> <outfile>`: schreibt die angezeigte Passphrase nach `<outfile>`.
  - `denied <user> <pw>`: Exit 0, wenn der Flow den Nutzer abweist.
  - `active <user> 0|1`
  - `nohash <hash>`: Exit 0, wenn der Wert in keinem Event steht.

- [ ] **Step 1: Compose-Datei**

`test/authentik/docker-compose.yml`:

```yaml
#  Integration test against a real authentik (spec 8.3). Not part of the
#  normal CI run; see .github/workflows/authentik-integration.yml.
name: akfr-it

x-authentik: &authentik
  image: ghcr.io/goauthentik/server:${AUTHENTIK_VERSION:-2026.8.3}
  environment:
    AUTHENTIK_SECRET_KEY: it-secret-key-not-a-real-one-0123456789abcdef
    AUTHENTIK_POSTGRESQL__HOST: postgresql
    AUTHENTIK_POSTGRESQL__USER: authentik
    AUTHENTIK_POSTGRESQL__NAME: authentik
    AUTHENTIK_POSTGRESQL__PASSWORD: it-db-not-a-real-one
    AUTHENTIK_BOOTSTRAP_PASSWORD: it-admin-not-a-real-one
    AUTHENTIK_BOOTSTRAP_TOKEN: it-bootstrap-token-not-a-real-one
    AUTHENTIK_ERROR_REPORTING__ENABLED: "false"
    AUTHENTIK_DISABLE_UPDATE_CHECK: "true"
  depends_on:
    postgresql: {condition: service_healthy}
  networks: [it]

services:
  postgresql:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: it-db-not-a-real-one
      POSTGRES_USER: authentik
      POSTGRES_DB: authentik
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U authentik"], interval: 5s, retries: 20}
    networks: [it]

  server:
    <<: *authentik
    command: server
    ports: ["127.0.0.1:19000:9000"]

  worker:
    <<: *authentik
    command: worker

  authentik_ldap:
    image: ghcr.io/goauthentik/ldap:${AUTHENTIK_VERSION:-2026.8.3}
    environment:
      AUTHENTIK_HOST: http://server:9000
      AUTHENTIK_INSECURE: "true"
      AUTHENTIK_TOKEN: ${IT_LDAP_TOKEN:-unset}
    networks:
      it:
        ipv4_address: 172.29.0.11

  certgen:
    build: ../e2e/client
    volumes: ["./.state:/out"]
    command: ["sh", "-c", "test -f /out/server.crt || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=radius.it.test' -keyout /out/server.key -out /out/server.crt"]
    networks: [it]

  freeradius:
    build: {context: ../.., dockerfile: Dockerfile}
    environment:
      #  No RADIUS outpost in this test; the address only has to be valid.
      AUTHENTIK_RADIUS_HOST: 172.29.0.10
      AUTHENTIK_RADIUS_SECRET: it-backend-secret-not-a-real-one
      RADIUS_SECRET: e2e-uplink-secret-not-a-real-one
      RADIUS_CLIENT_NET: 172.29.0.0/16
      TLS_CERT_PATH: /certs/server.crt
      TLS_KEY_PATH: /certs/server.key
      PEAP_ENABLE: "true"
      LDAP_HOST: 172.29.0.11
      LDAP_BASE_DN: dc=ldap,dc=goauthentik,dc=io
      LDAP_BIND_DN: cn=svc-wlan-ldap,ou=users,dc=ldap,dc=goauthentik,dc=io
      LDAP_BIND_PASSWORD: ${IT_LDAP_BIND_PASSWORD:-unset}
      LDAP_WLAN_GROUP_DN: cn=wlan,ou=groups,dc=ldap,dc=goauthentik,dc=io
    volumes: ["./.state:/certs:ro"]
    read_only: true
    tmpfs: [/run/radiusd, /tmp/radiusd]
    cap_drop: [ALL]
    networks: [it]

  client:
    build: ../e2e/client
    environment:
      RADIUS_SECRET: e2e-uplink-secret-not-a-real-one
    entrypoint: ["/auth.sh"]
    networks: [it]

networks:
  it:
    driver: bridge
    ipam:
      config:
        - subnet: 172.29.0.0/16
          ip_range: 172.29.128.0/17
```

`test/e2e/client/Dockerfile`: `RUN apk add --no-cache wpa_supplicant openssl` wird `RUN apk add --no-cache wpa_supplicant openssl openldap-clients`.

`.gitignore`: Zeile `test/authentik/.state/` anfügen.

- [ ] **Step 2: Treiber**

`test/authentik/drive.py`:

```python
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
        sys.exit("blueprint import failed:\n" + json.dumps(result.get("logs"), indent=1)[:4000])


def setup():
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
```

- [ ] **Step 3: Ablaufskript**

`test/authentik/run.sh`:

```bash
#!/usr/bin/env bash
# Integration test against a real authentik (spec 8.3): blueprint import, the
# WiFi password flow, the real LDAP outpost and PEAP through FreeRADIUS.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.yml)

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf .state; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; "${COMPOSE[@]}" logs --tail 30 freeradius authentik_ldap >&2 || true; exit 1; }
peap() {
	"${COMPOSE[@]}" run --rm --quiet-pull -e AUTH_METHOD=peap -e AUTH_USER="$1" \
		-e AUTH_PASSWORD="$2" client >/dev/null 2>&1
}

mkdir -p .state
echo "== building and starting authentik =="
"${COMPOSE[@]}" build --quiet
"${COMPOSE[@]}" run --rm certgen >/dev/null
"${COMPOSE[@]}" up -d postgresql server worker
deadline=$(( $(date +%s) + 300 ))
until curl -sf -o /dev/null http://127.0.0.1:19000/-/health/ready/; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "authentik did not become ready"
	sleep 5
done

echo "== blueprint, users, service account, outpost =="
python3 -I drive.py setup
set -a
# shellcheck disable=SC1091 # written by drive.py setup
. .state/it.env
set +a
"${COMPOSE[@]}" up -d authentik_ldap freeradius
deadline=$(( $(date +%s) + 120 ))
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$("${COMPOSE[@]}" ps -q authentik_ldap)")" = healthy ]; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "LDAP outpost did not become healthy"
	sleep 3
done

echo "== WiFi password flow =="
python3 -I drive.py flow peapuser it-user-pw-0123456789 .state/pw1
python3 -I drive.py denied outsider it-user-pw-0123456789 || fail "a user outside the WLAN group got the flow"

echo "== PEAP with the generated password =="
pw1="$(cat .state/pw1)"
deadline=$(( $(date +%s) + 60 ))
until peap peapuser "$pw1"; do
	[ "$(date +%s)" -lt "$deadline" ] || fail "PEAP with the generated password was rejected"
	sleep 3
done
if peap peapuser wrong-password; then fail "PEAP accepted a wrong password"; fi
if peap peapuser it-user-pw-0123456789; then fail "PEAP accepted the SSO password"; fi

echo "== deactivation applies at once =="
python3 -I drive.py active peapuser 0
if peap peapuser "$pw1"; then fail "PEAP accepted a deactivated user"; fi
python3 -I drive.py active peapuser 1
peap peapuser "$pw1" || fail "PEAP refused the reactivated user"

echo "== a new password replaces the old one =="
python3 -I drive.py flow peapuser it-user-pw-0123456789 .state/pw2
pw2="$(cat .state/pw2)"
[ "$pw1" != "$pw2" ] || fail "the flow showed the same passphrase again after saving"
if peap peapuser "$pw1"; then fail "the old WiFi password still works"; fi
peap peapuser "$pw2" || fail "the new WiFi password does not work"

echo "== the hash stays out of the event log, users cannot bind =="
hash="$(python3 -I -c 'import sys; ns={}; exec(open("../../authentik/src/md4.py").read(), ns); print(ns["md4"](sys.argv[1].encode("utf-16-le")).hex().upper())' "$pw2")"
python3 -I drive.py nohash "$hash" || fail "the NT hash appears in the event log"
if "${COMPOSE[@]}" run --rm --entrypoint ldapsearch client -x -H ldap://172.29.0.11:3389 \
	-D cn=peapuser,ou=users,dc=ldap,dc=goauthentik,dc=io -w it-user-pw-0123456789 \
	-b dc=ldap,dc=goauthentik,dc=io '(cn=*)' cn >/dev/null 2>&1; then
	fail "an ordinary user could bind to the wlan-ldap provider"
fi

echo
echo "PASS: authentik integration checks succeeded"
```

`.github/workflows/build.yml`, Job `lint`: `test/authentik/run.sh` an die `shellcheck`-Zeile anhängen.

- [ ] **Step 4: Lauf, Fehler beheben**

Run: `./test/authentik/run.sh`
Expected: `PASS: authentik integration checks succeeded`.

Typische Fehler und wo sie behoben werden:
- **Blueprint-Import scheitert:** Die Logs nennen das Modell bzw. Feld. Korrigieren in `authentik/src/wlan-passwort.yaml.in`, dann `python3 -I authentik/build_blueprint.py` und die Unit-Tests erneut ausführen.
- **`!Find` auf eine Gruppe liefert nichts:** Die Gruppen-Einträge stehen zuerst; prüfen, ob `state: created` sie bei Neuanlage wirklich anlegt.
- **Info-Feld leer:** `static` zeigt in dieser Version womöglich `placeholder` statt `initial_value`. Dann den `!Format`-Wert nach `placeholder` verschieben.
- **`add_user` oder die `roles`-PATCH abgelehnt:** Feldnamen über `GET /api/v3/core/groups/{pk}/` nachsehen und in `drive.py` anpassen.

Jede Abweichung vom Plan im Commit-Text nennen.

- [ ] **Step 5: Manueller Workflow**

`.github/workflows/authentik-integration.yml`:

```yaml
name: authentik-integration

#  Against a real authentik: blueprint import, the WiFi password flow, the LDAP
#  outpost and PEAP. Run before a release and after every authentik update.
on:
  workflow_dispatch:
    inputs:
      authentik_version:
        description: authentik version to test against
        required: true
        default: "2026.8.3"

permissions:
  contents: read

jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run the authentik integration test
        run: ./test/authentik/run.sh
        env:
          AUTHENTIK_VERSION: ${{ inputs.authentik_version }}
```

- [ ] **Step 6: e2e weiterhin grün (Client-Image geändert)**

Run: `./test/e2e/run.sh`
Expected: `PASS`.

- [ ] **Step 7: Commit**

```bash
git add test/authentik test/e2e/client/Dockerfile .gitignore .github/workflows authentik
git commit -m "test: Integrationstest gegen echtes authentik

Blueprint-Import, Passwort-Flow inklusive Manipulation und fehlender
Bestätigung, PEAP über den echten LDAP-Outpost, Deaktivierung, Wechsel
des Passworts, Event-Log und LDAP-Bind normaler Nutzer. Manuell per
workflow_dispatch.

Refs #14

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 7: Doku und Rundmail-Vorlage

Spec § 7, § 9, § 10. Englisch wie die bestehende Doku, die Rundmail auf Deutsch.

**Files:**
- Modify: `docs/authentik.md` (neuer Abschnitt 6), `docs/clients.md` (neuer Abschnitt am Anfang), `docs/migration.md` (Einleitung)
- Modify: `docs/troubleshooting.md`, `docs/monitoring.md`, `README.md`
- Create: `docs/rollout-mail.de.md`

**Interfaces:**
- Consumes: alle Namen aus den Global Constraints; die Log-Zeile aus Task 2/3; die Variablen aus Task 4; den Blueprint aus Task 5.

- [ ] **Step 1: `docs/authentik.md`, Abschnitt 6 anhängen**

````markdown
## 6. WiFi password for PEAP (optional)

PEAP-MSCHAPv2 lets every platform join with a username and password and no profile. It
needs the NT hash of the password, which authentik does not keep, so users get a separate,
generated **WiFi password** in the authentik portal. Their SSO password is not involved.

### Import the blueprint

**Customization → Blueprints → Import**, upload
[`authentik/blueprints/wlan-passwort.yaml`](../authentik/blueprints/wlan-passwort.yaml).

| Context key | Default | Meaning |
|---|---|---|
| `wlan_group` | `wlan` | who may get a WiFi password and join; created if missing, never changed |
| `ssid` | `WLAN` | shown to the user |
| `radius_server_name` | `radius.example.com` | the certificate name users must confirm |
| `ldap_search_group` | `wlan-ldap-search` | who may bind to the LDAP provider |
| `ldap_base_dn` | `dc=ldap,dc=goauthentik,dc=io` | base DN of the LDAP provider |

It creates the flow `wlan-passwort`, the portal tile **WLAN-Zugang**, and the LDAP
provider `wlan-ldap` with its own bind flow. Change the defaults by editing the context
block before the import.

### Service account, permission, outpost

The blueprint does not create these:

1. **Directory → Users → Create Service Account**:
   - Name `svc-wlan-ldap`.
   - Clear **Create group** and **Expiring**. An expired token switches PEAP off without
     warning.
2. Add `svc-wlan-ldap` to the group `wlan-ldap-search`.
3. **Directory → Roles → Create**, name `wlan-ldap-search`. Then:
   - Assign the role to the group `wlan-ldap-search`.
   - On the provider `wlan-ldap` (**Permissions** tab), grant the role
     **Search full LDAP directory**.
4. **Applications → Outposts → Create**:
   - Type **LDAP**, provider `wlan-ldap`, no service connection.
   - Copy the token into `AUTHENTIK_LDAP_TOKEN`.
5. **Directory → Tokens**, token `service-account-svc-wlan-ldap-password` → copy into
   `LDAP_BIND_PASSWORD`.
6. Deploy with [`docker-compose.peap.yml`](../docker-compose.peap.yml) as an additional
   Compose file and set the `LDAP_*` variables from `.env.example`.

**This provider hands out NT hashes.** Do not attach it to any other application, and keep
the group `wlan-ldap-search` to the service account. Rotating the token: create a new one
for `svc-wlan-ldap`, update `LDAP_BIND_PASSWORD`, redeploy, delete the old token.

### What users and the helpdesk do

- **Users:** open **WLAN-Zugang** in the portal, note the six-word password, confirm.
  Getting a new one invalidates the old one on every device.
- **Helpdesk:** cannot see or set a WiFi password. Deleting the attribute
  `wifi-password-nthash` on the user locks WiFi until the user fetches a new one.
- **Leavers:** deactivating the user, or removing them from `wlan`, refuses the next
  login. No cache is involved: the provider runs in `direct` mode.

### Security

- The NT hash is equivalent to the WiFi password: anyone with the authentik database, an
  admin account or the service account token has WiFi access for every user — not their
  SSO account.
- Without a profile users confirm the server certificate by tapping. A fake access point
  can record the exchange and recover the NT hash offline (about 2^56 DES operations).
  Tell users the certificate name; managed devices should still get a profile.
- The plaintext passphrase sits in the user's session until it is saved or the session
  expires.
````

- [ ] **Step 2: `docs/clients.md`, Abschnitt vor „## The certificate trust problem“ einfügen**

```markdown
## PEAP without a profile (WiFi password)

With `docker-compose.peap.yml` deployed, every platform joins from its normal WiFi dialog.
Username: the authentik username. Password: the WiFi password from the portal tile
**WLAN-Zugang** (see [authentik.md § 6](authentik.md#6-wifi-password-for-peap-optional)),
**not** the SSO password.

| Platform | Steps |
|---|---|
| Windows 10/11 | Pick the SSID, enter username and WiFi password, click **Connect** when it asks about the server — after checking the certificate name under **Show certificate details**. |
| iOS / iPadOS | Pick the SSID, enter username and password, tap **Trust** after checking the certificate name. |
| macOS | As iOS; macOS may ask for the login password to store the certificate trust. |
| Android 11+ | EAP method **PEAP**, phase 2 **MSCHAPV2**, CA certificate **Use system certificates**, domain = the RADIUS server name, identity = username, anonymous identity empty. |

The certificate name to confirm is shown on the WiFi password page. A different name means
a different network: do not connect.

Verified on real devices: pending, see the checklist in [migration.md](migration.md).
```

- [ ] **Step 3: `docs/migration.md`, Einleitung**

Die zwei Absätze von **This stack is not a drop-in for that.** bis „… keeping MSCHAPv2.“ ersetzen durch:

```markdown
**Two ways across, with different client cost:**

- **PEAP-MSCHAPv2 with a WiFi password** ([authentik.md § 6](authentik.md#6-wifi-password-for-peap-optional)).
  The inner method stays MSCHAPv2, so clients need no new profile — but every user needs a
  new *password*: the generated WiFi password replaces the AD password for WiFi. Plan a
  mail with the portal link (template: [rollout-mail.de.md](rollout-mail.de.md)) and keep
  the old server running until users have switched. No AD, no `ntlm_auth`.
- **EAP-TTLS/PAP or EAP-TLS.** The inner method changes, so **every client needs a new
  profile**. Plan the rollout mechanism (Intune, GPO, `.mobileconfig`, NetworkManager)
  before the cutover, not after.
```

Und in der „Cutover checklist“ nach „One real client of each platform …“ ergänzen:

```markdown
- [ ] With PEAP: users told, WiFi passwords fetched, one device per platform (Windows,
      iOS, macOS, Android) joined without a profile.
```

- [ ] **Step 4: `docs/troubleshooting.md` und `docs/monitoring.md`**

`docs/troubleshooting.md`, unter „## Symptoms“ anfügen:

```markdown
**PEAP login refused, `peap: no active WLAN user with a WiFi password: <user>`** — the
directory had no match: the user is deactivated, not in the WLAN group, has no WiFi
password yet, or typed a different username. EAP-TTLS is unaffected.

**PEAP refused, `rlm_ldap … failed: Can't contact LDAP server`** — the LDAP outpost is
down or not at `AUTHENTIK_LDAP_IP`. PEAP fails within seconds; EAP-TTLS keeps working. The
connection pool reconnects by itself once the outpost is back.

**PEAP refused, `rlm_ldap … failed: Invalid credentials`** — `LDAP_BIND_PASSWORD` is not a
valid token of `svc-wlan-ldap`, or the token expired.
```

`docs/monitoring.md`, Tabelle der Muster, neue Zeilen:

```markdown
| `rlm_ldap .* failed: Invalid credentials` | PEAP service account token wrong or expired; every PEAP login fails | High |
| `rlm_ldap .* failed: Can't contact LDAP server` | LDAP outpost down; PEAP fails, EAP-TTLS unaffected | High |
| `peap: no active WLAN user with a WiFi password` | a refused PEAP login; many in a short time point at a rollout gap | Information |
```

- [ ] **Step 5: `README.md`**

- Unter „## Why this exists“, nach dem Diagramm, anfügen:

```markdown
Optionally, with [`docker-compose.peap.yml`](docker-compose.peap.yml), FreeRADIUS also
speaks **PEAP-MSCHAPv2**: no client profile on any platform, with a separate WiFi password
that users generate in authentik and that FreeRADIUS checks via the authentik LDAP
outpost. See [docs/authentik.md § 6](docs/authentik.md#6-wifi-password-for-peap-optional).
```

- Unter „## Security properties“ als letzten Punkt der Liste:

```markdown
- **With PEAP, authentik stores an NT hash per user** (`wifi-password-nthash`). It is
  equivalent to that user's WiFi password — not to their SSO password — and the LDAP
  service account can read all of them.
```

- In „## Documentation“ ergänzen: `- [docs/rollout-mail.de.md](docs/rollout-mail.de.md) — template mail to users (German)`.

- [ ] **Step 6: `docs/rollout-mail.de.md`**

```markdown
# Vorlage: Rundmail zum neuen WLAN-Zugang

Platzhalter in spitzen Klammern ersetzen. Ohne Site-Daten im Repo; die ausgefüllte
Fassung gehört nicht hierher.

---

**Betreff:** Neues WLAN-Passwort für <SSID> – bitte bis <Datum> abholen

Hallo,

ab <Datum> meldest du dich im WLAN **<SSID>** mit einem eigenen **WLAN-Passwort** an. Es
ist nicht dein normales Anmeldepasswort.

So geht's:

1. Öffne <Portal-URL> und melde dich wie gewohnt an.
2. Klicke auf **WLAN-Zugang**. Dort steht dein WLAN-Passwort aus sechs Wörtern. Notiere
   es – es wird nur einmal angezeigt.
3. Verbinde dein Gerät mit **<SSID>**: Benutzername wie im Portal, Passwort = das
   WLAN-Passwort.
4. Dein Gerät fragt nach einem Zertifikat. Bestätige es nur, wenn es auf
   **<RADIUS-Servername>** lautet.

Passwort vergessen oder Gerät verloren? Hol dir im Portal einfach ein neues. Das alte gilt
dann sofort nicht mehr; trag das neue auf allen deinen Geräten ein.

Bis <Datum> funktioniert das bisherige WLAN parallel weiter.

Fragen: <Kontakt>
```

- [ ] **Step 7: Links prüfen**

Run: `grep -ohE '\]\(([^)#]+)' README.md docs/*.md | sed 's/^](//' | grep -v '^http' | sort -u | while read -r p; do for base in . docs; do [ -e "$base/$p" ] && continue 2; done; echo "broken: $p"; done`
Expected: keine Ausgabe.

- [ ] **Step 8: Commit**

```bash
git add docs README.md
git commit -m "docs: WLAN-Passwort für PEAP, Clients ohne Profil, Rundmail

Refs #14

Claude-Session: https://claude.ai/code/session_0121b3AM2hP1mx8TPxGAJ1sN"
```

---

### Task 8: Abschluss

- [ ] **Step 1: Alles einmal komplett**

```bash
shellcheck freeradius/entrypoint.sh freeradius/healthcheck.sh test/e2e/client/auth.sh test/e2e/run.sh test/authentik/run.sh
python3 -I -m unittest discover -s test/authentik -p 'test_*.py'
python3 -I authentik/build_blueprint.py --check
./test/e2e/run.sh
./test/authentik/run.sh
```

Expected: alles grün, beide Suites mit `PASS`.

- [ ] **Step 2: Spec nachziehen**

`docs/superpowers/specs/2026-10-13-peap-wlan-passwort-design.md`: jede Abweichung eintragen, die die Tasks im Commit-Text genannt haben (etwa die Ausweichlösung für `linelog` oder geänderte Blueprint-Felder), mit einer Zeile in § 13. Gibt es keine, entfällt der Schritt. Commit mit `Refs #14`.

- [ ] **Step 3: Übergabe an Christian**

Melden:
- was erledigt ist, mit Commit-Liste und Testergebnissen
- dass die Gerätetests (spec § 8.4) noch ausstehen
- dass #14 deshalb offen bleibt

Push und PR (`feat/peap-wlan-passwort` → `develop`) nur auf sein Okay. Der PR-Text endet mit `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
