# Design: PEAP-MSCHAPv2 mit eigenem, generiertem WLAN-Passwort aus authentik

Datum: 2026-10-13
Status: Revision 5, umgesetzt; Gerätetests (§ 8.4) stehen noch aus
Issues: #14 (Spike-Ergebnis dort), #15 (feste Adressen). Bezug: #11, #7/#12 (für dieses Ziel zurückgestellt), #8

## 1. Ziel

WLAN-Login mit Benutzername und Passwort auf iOS, Android, Windows und macOS, **ohne
Client-Zertifikate und ohne vorab verteilte WLAN-Profile**. Das kann von den gängigen
Methoden nur PEAP-MSCHAPv2: alle vier Plattformen richten es aus dem normalen
Verbindungsdialog ein. EAP-TTLS/PAP, das der Stack heute kann, braucht auf Windows und Apple
ein Profil.

Erfolg heißt:

- Ein Nutzer der WLAN-Gruppe holt sich im authentik-Portal ein WLAN-Passwort und verbindet
  damit jedes seiner Geräte ohne weitere Vorbereitung.
- Deaktivieren in authentik oder Entfernen aus der WLAN-Gruppe sperrt ihn **sofort**.
- Bestehende TTLS/PAP-Clients funktionieren unverändert weiter, **auch wenn der LDAP-Outpost
  ausgefallen ist** – beim laufenden Betrieb wie beim Start und Neustart von FreeRADIUS.
- Eine Bestandsinstallation ohne die neue Option verhält sich exakt wie heute.

## 2. Entscheidungen (mit Christian abgestimmt)

| Frage | Entscheidung |
|---|---|
| Methode | PEAP-MSCHAPv2 zero-touch (Option B). TTLS/PAP + Onboarding-Seite (Option A) ist ein späterer Umbau. |
| WLAN-Passwort = SSO-Passwort? | **Nein.** Eigenes WLAN-Passwort, getrennt vom SSO-Passwort. |
| Wer wählt das Passwort? | **authentik erzeugt es.** Der Nutzer sieht es einmalig. |

Das eigene Passwort löst den Haupt-Befund des Spikes: Ein Admin-Reset des SSO-Passworts ließ
dort den alten NT-Hash stehen. Mit getrennten Passwörtern berührt ein SSO-Reset das WLAN
nicht, und es gibt genau **einen** nutzerbedienbaren Weg, der den Hash schreibt.

## 3. Nicht-Ziele

- Passwörter pro Gerät (#11). Bräuchte eigene Benutzernamen pro Gerät.
- Automatischer Ablauf des WLAN-Passworts. Der Zeitstempel wird gespeichert (§ 5.2), die
  Prüfung kommt erst bei Bedarf.
- Dynamisches VLAN für PEAP-Nutzer. `Filter-Id` kommt heute aus dem RADIUS-Outpost, den der
  PEAP-Pfad nicht berührt. PEAP-Nutzer bleiben im VLAN der SSID. Folge-Issue.
- Realm-Formen `DOMAIN\user` und `user@domain` (#8). Akzeptiert wird der authentik-Username.
- Gäste und Geräte ohne Person.
- Ein Helpdesk-Flow „WLAN-Passwort für Nutzer X zurücksetzen“. Admins löschen das Attribut.

## 4. Architektur

```
                    ┌── EAP-TTLS/PAP (wie heute) ──▶ RADIUS-Outpost ──▶ authentik
UniFi AP ──802.1X──▶ FreeRADIUS
                    └── PEAP/MSCHAPv2 ──LDAP──▶ LDAP-Outpost ──▶ authentik
                         (prüft MSCHAPv2       (liefert den NT-Hash nur für aktive
                          gegen NT-Hash)        Mitglieder der WLAN-Gruppe)

Nutzer ──Browser──▶ authentik-Flow „WLAN-Passwort“ ──schreibt──▶ user.attributes
```

Drei Teile mit je einer Aufgabe:

1. **authentik-Konfiguration** (Blueprint im Repo): Flow, der ein Passwort erzeugt und den
   NT-Hash speichert; Anwendung als Kachel; LDAP-Provider samt Servicekonto.
2. **LDAP-Outpost** als dritter Container, nur im Docker-Netz erreichbar.
3. **FreeRADIUS**: zusätzlich `peap`, `inner-eap`, `mschap` und `ldap`, hinter einem
   Schalter. PEAP hängt am LDAP-Outpost, TTLS nie.

## 5. authentik

Ein Blueprint `authentik/blueprints/wlan-passwort.yaml` liefert Flow, Prompts, Policy,
Anwendung, Gruppen, Bind-Flow und LDAP-Provider. Von Hand angelegt werden das Servicekonto,
seine Suchberechtigung und der LDAP-Outpost; die Doku beschreibt die Schritte. Der Blueprint
entsteht aus Quelldateien unter `authentik/src/`, damit die Expressions testbar sind.
Die Werte, die pro Installation abweichen (Gruppenname, Servername des Zertifikats, SSID,
authentik-URL, Base-DN), kommen als Blueprint-Kontext; Standardwerte stehen in § 12.

### 5.1 Flow „WLAN-Passwort“

- Slug `wlan-passwort`, Designation `stage_configuration`, Authentication
  `require_authenticated`.
- Flow-Policy-Binding: Mitglied der WLAN-Gruppe. Wer nicht Mitglied ist, wird abgewiesen.

**Grundsatz: Pro Flow-Durchlauf gibt es genau eine Passphrase, und sie liegt nur auf dem
Server.** Anzeige und Speichern leiten sich aus diesem einen Wert ab. Nichts, was der Browser
zurückschickt, bestimmt das gespeicherte Passwort. Damit braucht es keinen HMAC, und ein
manipulierter POST kann kein selbst gewähltes Passwort setzen.

Ablauf:

1. **Erzeugen.** Die `initial_value_expression` des Felds `wifi_password` erzeugt die
   Passphrase **nur beim Rendern (GET)** und legt sie in der **Session** unter `wifi_password_pending` ab, zusammen mit
   dem aktuellen `wifi-password-set-at` des Nutzers als `base`. Steht dort schon ein Wert mit
   derselben `base`, gibt sie diesen zurück. Unterscheidet sich `base`, ist das Passwort
   inzwischen gespeichert worden, und sie erzeugt ein neues. Geprüft (V1):
   - authentik wertet Read-only-Felder beim Rendern **und** beim Absenden serverseitig neu
     aus und ignoriert den POST-Wert.
   - Ein Schreiben in `prompt_context` überlebt den Request nicht: Jedes Rendern lieferte
     einen anderen Wert.
   - Der Session-Wert bleibt über erneutes Rendern und Absenden stabil.

   Ein Absenden (POST) ohne passenden Session-Wert erzeugt **nichts**: Das Feld liefert dann
   `""`, und die Policy lehnt mit „abgelaufen“ ab (veralteter Tab, § 5.1 unten).
2. **Anzeigen.** Prompt-Stage `wlan-passwort-anzeige`:

   | Feld | Typ | Inhalt |
   |---|---|---|
   | `wifi_password` | `text_read_only` | Passphrase aus der Session |
   | `wifi_info` | `static` | SSID, Benutzername, erwarteter Zertifikatsname, Hinweis „wird nur jetzt angezeigt“ |
   | `wifi_ack` | `checkbox`, Pflicht | „Ich habe das Passwort notiert. Das bisherige WLAN-Passwort wird damit ungültig.“ |

3. **Speichern.** Eine Validierungs-Policy `wlan-passwort-speichern` an der Prompt-Stage läuft
   beim Absenden. In `prompt_data` steht dort der serverseitig neu ausgewertete Wert von
   `wifi_password`. Die Policy verlangt, dass er dem Session-Wert entspricht, und:
   1. lehnt ab, wenn `wifi_ack` nicht genau `True` ist. Eine Pflicht-Checkbox mit `false`
      gilt in authentik als ausgefüllt; geprüft, ohne diese Prüfung wurde gespeichert;
   2. bestimmt den Nutzer aus `request.user` (der Flow verlangt eine Anmeldung);
   3. berechnet den NT-Hash, `MD4(UTF-16LE(passwort))`, mit der eingebetteten MD4
      (authentik hat kein MD4, OpenSSL 3);
   4. schreibt in einer Transaktion mit `select_for_update()` auf den frisch gelesenen
      Nutzer nur die beiden Schlüssel aus § 5.2 und speichert mit
      `save(update_fields=["attributes"])`. So überschreibt sie keinen parallelen
      Schreibvorgang auf andere Attribute.
   5. entfernt `wifi_password_pending` aus der Session;
   6. gibt `True` zurück. Bei jeder Exception gibt sie `False` mit einer Meldung zurück und
      schreibt nichts.

   Der Flow endet und leitet zur Bibliothek.

Erzeugen beim Anzeigen, Speichern erst beim Absenden: Bricht der Nutzer ab, bleibt das
bisherige WLAN-Passwort gültig, und beim nächsten Öffnen erscheint dieselbe, noch nicht
aktive Passphrase.

In der Probe lief die Validierungs-Policy im Prozess des Web-Workers, und das Entfernen aus der
Session wirkte. Darauf verlässt sich das Design nicht: Läuft die Policy in einem anderen
Prozess und geht das Entfernen verloren, sorgt die `base`-Prüfung aus Schritt 1 trotzdem für
ein neues Passwort beim nächsten Durchlauf.

Geprüft gegen authentik 2026.8.3:

| Fall | Ergebnis |
|---|---|
| zweimal rendern, dann absenden | dieselbe Passphrase; gespeicherter Hash passt zum angezeigten Wert |
| POST mit fremdem `wifi_password` | ignoriert, gespeichert wird der angezeigte Wert |
| abbrechen, neu öffnen | dieselbe Passphrase, nichts gespeichert |
| nach dem Speichern neu öffnen | neue Passphrase |
| ohne Bestätigung absenden | abgelehnt mit Meldung, nichts gespeichert; ein schon gespeicherter Hash bleibt unverändert |
| veralteter Tab absenden (zweiter Tab, nachdem der erste gespeichert hat) | abgelehnt als abgelaufen, gespeicherter Hash bleibt der angezeigte; mit der früheren Fassung (Erzeugen auch beim Absenden) wurde eine nie gesehene Passphrase gespeichert |
| Nutzer nicht in der WLAN-Gruppe | Flow verweigert (`access-denied`) |

### 5.2 Gespeicherte Daten

| Attribut | Inhalt | Wer schreibt |
|---|---|---|
| `wifi-password-nthash` | NT-Hash, 32 Hex-Zeichen, Großbuchstaben | nur die Policy aus § 5.1 |
| `wifi-password-set-at` | Zeitpunkt der Erzeugung, ISO 8601, UTC | nur die Policy aus § 5.1 |

Zu den Namen:

- Der Bindestrich macht die Namen zu gültigen LDAP-Attributnamen (RFC 4512 erlaubt keinen
  Unterstrich). Das braucht das Test-Directory (§ 8.1); authentik reicht den Schlüssel laut
  Spike unverändert durch.
- `password` im Namen soll dafür sorgen, dass authentiks Bereinigung (`PASS` im Schlüssel)
  den Wert in Event-Diffs schwärzt. Ohne Enterprise-Lizenz schreibt authentik bei
  `model_updated` gar keinen Diff (geprüft, V4). Der Name schützt erst, falls die Lizenz
  später dazukommt; das ist ungeprüft.

Der Hash ist die einzige dauerhafte Ablage. Die Passphrase steht im Klartext in der Session,
und Sessions liegen in PostgreSQL. Sie verschwindet beim Speichern, bei Abbruch spätestens mit
dem Ablauf der Session; bis dahin ist sie auch in DB-Backups denkbar. Das ist vertretbar, weil
die Passphrase nirgends sonst gilt.

Löschen von `wifi-password-nthash` sperrt den WLAN-Zugang des Nutzers, bis er ein neues
Passwort holt.

Kein **nutzerbedienbarer** Weg außer diesem Flow darf diese Attribute schreiben. Admins können
`attributes` in UI und API jederzeit ändern; das ist gewollt (Helpdesk löscht). Prompt-Stages
schreiben nur deklarierte Felder. Die Doku sagt, dass ein Prompt mit Feldnamen
`attributes.wifi-password-*` in einem nutzerbedienbaren Flow diese Garantie bricht.

### 5.3 Passphrase

- **Sechs** Wörter aus der **EFF Short Wordlist 1** (CC BY 3.0), mit Bindestrich getrennt,
  Kleinbuchstaben. Beispiel aus der Probe: `sleet-stray-agent-data-swear-gloss`.
- Die Liste hat 1296 Einträge. `yo-yo` fällt heraus, weil der Bindestrich das Trennzeichen
  ist; es bleiben 1295 Wörter mit 3 bis 5 Buchstaben.
- Entropie 6 × log2(1295) ≈ 62 Bit. Zufall aus `secrets.choice`.
- Die Liste steht direkt in der Expression; die gesamte Expression ist rund 11 KB groß.
- Kurze, gängige Wörter ohne Umlaute, damit das Tippen am Handy klappt. Englisch ist der Preis
  für eine fertig lizenzierte Liste; eine deutsche Liste kann später die Datei ersetzen.

Warum 62 Bit: Ein Evil-Twin schneidet Challenge und Response eines MSCHAPv2-Austauschs mit.
Daraus gibt es zwei Offline-Wege:

- **Über DES:** MSCHAPv2 rechnet drei DES-Operationen mit Teilen des NT-Hashes. Der dritte
  Schlüssel hat nur zwei unbekannte Bytes, die ersten beiden kosten zusammen etwa 2^56. Das
  liefert den NT-Hash, **unabhängig von der Passwortstärke**, und der Hash reicht für den
  WLAN-Zugang.
- **Über das Passwort:** Kandidaten raten und je MD4 plus DES rechnen (hashcat-Modus 5500).
  Bei fünf Wörtern (≈ 51,7 Bit) wäre das billiger als der DES-Weg, grob ein Tag auf einer
  aktuellen GPU.

Mit sechs Wörtern ist der DES-Weg der billigste. Mehr Entropie kauft nichts mehr, weil der
DES-Weg bleibt. Gegen den DES-Weg hilft nur, dass Nutzer das Zertifikat prüfen (§ 10).

### 5.4 Anwendung „WLAN-Zugang“

- Anwendung ohne Provider, Launch-URL `/if/flow/wlan-passwort/`.
- Policy-Binding: WLAN-Gruppe. Nur Mitglieder sehen die Kachel.

### 5.5 LDAP-Provider und Servicekonto

- Eigener LDAP-Provider `wlan-ldap` mit eigener Anwendung, ausschließlich für FreeRADIUS. Die
  Doku warnt: Dieser Provider gibt NT-Hashes heraus und darf nicht für andere Anwendungen
  wiederverwendet werden.
- Search-Mode `direct`, Bind-Mode `direct`. `cached` würde Deaktivierungen verzögern.
- Eigener Bind-Flow für den Provider: Identification und Password ohne MFA, Password-Stage mit
  dem Backend „authentik Tokens“. Mit MFA im Bind-Flow scheitert der Bind.
- Servicekonto `svc-wlan-ldap` (Typ Service Account, angelegt mit `expiring: false`), Rolle
  mit der Permission `search_full_directory` auf diesem Provider. authentik legt dabei selbst
  einen Token mit Intent `app_password` und `expiring: false` an; mit ihm bindet FreeRADIUS.
  Ein abgelaufener Token würde PEAP leise abschalten. Rotation ist ein dokumentierter,
  manueller Schritt; ein fehlschlagender Bind erzeugt eine eigene Log-Zeile (§ 9), die das
  Monitoring auswertet.
- Die Anwendung des Providers ist an die Gruppe `wlan-ldap-search` gebunden, in der nur das
  Servicekonto ist; normale Nutzer können sich dort nicht binden.

Geprüft (V3, V5):
- Der Token-Bind über den Bind-Flow funktioniert.
- Der Filter aus § 6.4 liefert `wifi-password-nthash` und `ak-active`.
- Ein Nutzer ohne Hash wird nicht gefunden.
- Ein falscher Token ergibt `Invalid credentials`.
- Ein normaler Nutzer bekommt `Insufficient access`.

## 6. Stack

### 6.0 Netz und feste Adressen (#15, Voraussetzung)

Entschieden in § 11a. Dieser Teil gilt auch ohne PEAP. Er schließt #15 und kommt im Plan
**zuerst**, als eigener Commit.

- Das Netz `radius` in `docker-compose.yml` bekommt ein festes IPAM-Subnetz
  `${RADIUS_NET_SUBNET:-172.31.253.0/24}` und ein `ip_range`
  `${RADIUS_NET_DYNAMIC:-172.31.253.128/25}`. Docker vergibt dynamische Adressen (etwa an
  `freeradius`) nur aus diesem oberen Bereich, feste Adressen liegen darunter und können nicht
  belegt sein.
- `authentik_radius` bekommt `ipv4_address: ${AUTHENTIK_RADIUS_IP:-172.31.253.10}`, der
  LDAP-Outpost später `${AUTHENTIK_LDAP_IP:-172.31.253.11}`.
- `freeradius` bekommt `AUTHENTIK_RADIUS_HOST: ${AUTHENTIK_RADIUS_IP:-172.31.253.10}`.
- `entrypoint.sh` verlangt für `AUTHENTIK_RADIUS_HOST` eine literale IPv4-Adresse und bricht
  sonst mit Meldung ab. Auflösen und Adress-Watcher aus #5 entfallen. Ist
  `OUTPOST_RESOLVE_INTERVAL` gesetzt, erscheint eine Warnung, dass die Variable keine Wirkung
  mehr hat; sie verschwindet aus `.env.example` und `docker-compose.yml`.
- **Umstieg einer bestehenden Installation:** Geprüft mit Compose 5.5.1: Compose erkennt die
  geänderte Netz-Konfiguration, legt das Netz neu an und erzeugt die Container neu; der
  Outpost landet auf seiner festen Adresse. Für ältere Compose-Versionen, auch die in
  Portainer gebündelte, nennt die Doku den Ausweg: Stack stoppen, altes Netz entfernen, neu
  deployen.
- Das Subnetz darf mit keinem Netz am Host oder im LAN kollidieren. Deshalb ist es eine
  Variable; `.env.example` erklärt das.
- e2e: Die Stufe „Outpost auf neuer Adresse neu erzeugt“ (#5) wird zu „Outpost neu erzeugt,
  behält seine Adresse, Authentifizierung geht ohne Neustart von radiusd weiter“. Dazu eine
  Stufe, in der `AUTHENTIK_RADIUS_HOST` ein Name ist: Der Entrypoint bricht ab.
- Doku: `troubleshooting.md` und `monitoring.md` verlieren die Zeile „outpost address changed,
  restarting radiusd“.

### 6.1 Compose

- Neue Datei `docker-compose.peap.yml`, in Portainer als zusätzliche Compose-Datei
  eingebunden. Sie fügt hinzu:
  - Dienst `authentik_ldap`, `ghcr.io/goauthentik/ldap:${AUTHENTIK_VERSION}`, eigener
    Outpost-Token `AUTHENTIK_LDAP_TOKEN`, kein veröffentlichter Port, Netz `radius` mit
    `ipv4_address: ${AUTHENTIK_LDAP_IP:-172.31.253.11}`. Der eingebaute Healthcheck des Images
    bleibt, wie beim RADIUS-Outpost.
  - für `freeradius`: die LDAP-Variablen und `PEAP_ENABLE=true`. **Kein**
    `depends_on: service_healthy` auf `authentik_ldap`: TTLS darf nicht auf LDAP warten. Ein
    PEAP-Login kurz nach dem Deploy scheitert, bis der LDAP-Outpost bereit ist.
- Ohne die Zusatzdatei ändert sich nichts.

### 6.2 Neue Variablen

| Variable | Pflicht bei PEAP | Bedeutung |
|---|---|---|
| `PEAP_ENABLE` | – | `true` schaltet PEAP ein. Standard `false`. |
| `LDAP_HOST` | – | Literale IPv4-Adresse des LDAP-Outposts; die Zusatzdatei setzt sie aus `AUTHENTIK_LDAP_IP`. Ein Name führt zum Abbruch (§ 6.0). |
| `LDAP_PORT` | – | Standard `3389` (Klartext-Port des Outposts) |
| `LDAP_BASE_DN` | ja | Base-DN des Providers, z. B. `dc=ldap,dc=goauthentik,dc=io` |
| `LDAP_BIND_DN` | ja | DN des Servicekontos |
| `LDAP_BIND_PASSWORD` | ja | App-Passwort-Token des Servicekontos |
| `LDAP_WLAN_GROUP_DN` | ja | DN der WLAN-Gruppe |

LDAP ohne TLS im privaten Docker-Netz, so wie heute PAP zum RADIUS-Outpost. Das Bedrohungsmodell
ist dasselbe: Wer den Host hat, sieht ohnehin alles. README und Doku sagen das.

### 6.3 entrypoint.sh

- `PEAP_ENABLE` ist `true` oder `false`, sonst Abbruch mit Meldung.
- Bei `true` werden die Pflichtvariablen geprüft; fehlt eine, bricht das Skript mit Meldung
  ab. Das ist ein Konfigurationsfehler, kein Ausfall.
- Die drei DNs müssen auf `^[A-Za-z0-9=,._ -]{1,255}$` passen, sonst Abbruch. Sie landen
  ungeescaped in der Konfiguration und im LDAP-Filter (`$ENV{}` wird beim Parsen eingesetzt,
  vor dem Escaping des Moduls). Ausgeschlossen sind damit `( ) * \ %`, Anführungszeichen,
  NUL und Zeilenumbrüche. Die Obergrenze ist 255: Das `grep -E` von busybox im Image
  (musl, `RE_DUP_MAX` 255) lehnt `{1,256}` ab. authentik-Gruppennamen mit anderen Zeichen brauchen einen anderen
  Gruppennamen.
- `LDAP_HOST` muss eine literale IPv4-Adresse sein, wie `AUTHENTIK_RADIUS_HOST` (§ 6.0). Es
  gibt kein Auflösen und keinen Watcher. Der Pool verbindet nach Fehlern selbst neu. Geprüft:
  Nach Stopp und Neustart des Outposts geht PEAP ohne Neustart von radiusd wieder, und bei
  gestopptem Outpost endet eine PEAP-Anfrage über die IP nach etwa 2 s.
- Schaltmechanismus nach dem Muster von `vlan-map.conf`: Das Skript schreibt drei Dateien
  unter `/run/radiusd/`. Bei `true` enthält jede ein `$INCLUDE` auf eine Datei im Image, bei
  `false` ist sie leer:

  | Datei | eingebunden in | enthält bei `true` |
  |---|---|---|
  | `peap-modules.conf` | `radiusd.conf`, Block `modules {}` | `ldap`, `inner-eap`, `linelog` aus `/etc/raddb/peap/`; `mschap` und `pap` sind im Basis-Image schon aktiv |
  | `peap-eap.conf` | `mods/eap`, Block `eap {}` | den `peap {}`-Block |
  | `peap-site.conf` | `radiusd.conf`, nach `sites-enabled/` | den Server `peap-inner-tunnel` |

  Die Module liegen im Image unter `/etc/raddb/peap/`, **nicht** in `mods-enabled/`; sonst
  würde `ldap` auch bei `false` instanziiert. Das Dateisystem bleibt read-only.

### 6.4 FreeRADIUS

Basis-Image `freeradius/freeradius-server:3.2.10-alpine` bringt `rlm_ldap`, `rlm_mschap`,
`rlm_eap_peap` und `rlm_eap_mschapv2` mit (geprüft).

- **`peap {}`** in `eap`: `tls = tls-common`, `default_eap_type = mschapv2`,
  `virtual_server = "peap-inner-tunnel"`, `copy_request_to_tunnel = no`,
  `use_tunneled_reply = no`. `use_tunneled_reply = no` hält die inneren Reply-Attribute,
  vor allem den inneren `User-Name`, im Tunnel; der äußere Accept trägt die äußere Identität
  `anonymous`. `MS-CHAP2-Success` entfernt `eap_mschapv2` selbst, auch mit `yes`. Das passt
  zum Nicht-Ziel „kein VLAN für PEAP“.
- **`default_eap_type` bleibt `ttls`.** Clients ohne Profil antworten auf den TTLS-Vorschlag
  mit NAK und bekommen PEAP; TTLS-Bestandsclients brauchen keine Extra-Runde. Die e2e prüft
  beide Richtungen.
- **`ldap`-Modul** (`/etc/raddb/peap/ldap`):
  - Server `$ENV{LDAP_HOST}`, Port `$ENV{LDAP_PORT}`, Bind und Base aus den Variablen.
  - `user { filter = "(&(cn=%{User-Name})(ak-active=TRUE)(memberOf=$ENV{LDAP_WLAN_GROUP_DN})(wifi-password-nthash=*))" }`.
    Der Filter steht im Modul, nicht in unlang; nur dort escaped `rlm_ldap` `User-Name`.
  - `update { control:NT-Password := 'wifi-password-nthash' }` als Mapping-Sektion im Modul.
  - Pool `start = 0`, `min = 0`, `max = 8`, `idle_timeout = 60`, `lifetime = 300`. Mit
    `start = 0` startet radiusd ohne erreichbares Directory.
  - Timeouts: Verbindung 3 s, Abfrage 3 s. Beides liegt unter `max_request_time` und unter
    dem EAP-Timeout der AP für eine Runde.
- **`mschap`-Modul** mit Standardwerten, kein `ntlm_auth`. Die MPPE-Optionen des Moduls
  wirken bei PEAP nicht: MSK und `MS-MPPE-*-Key` im äußeren Accept leitet das äußere `eap` aus
  dem TLS-Tunnel ab.
- **`inner-eap`**: `eap`-Instanz nur mit `mschapv2`.
- **Neuer Virtual Server `peap-inner-tunnel`**, getrennt von `proxy-inner-tunnel`. So lief er
  in der Probe:

  ```
  authorize {
      inner-eap { ok = return }    # EAP-Identity-Runde
      ldap
      if (notfound) { reject }     # kein aktiver WLAN-Nutzer mit WLAN-Passwort
      pap                          # normalisiert NT-Password: 32 Hex-Zeichen → 16 Bytes
  }
  authenticate {
      Auth-Type inner-eap { inner-eap }
      mschap                       # erzeugt "Auth-Type mschap", das eap_mschapv2 aufruft
  }
  ```

  Gegenüber Revision 2 korrigiert, beides in der Probe gefunden:
  - Die Instanz `inner-eap` verlangt eine Sektion `Auth-Type inner-eap`. Mit `Auth-Type eap`
    bricht radiusd beim Start ab.
  - `eap_mschapv2` ruft `Auth-Type mschap` auf. Eine Sektion `Auth-Type MS-CHAP` allein findet
    es nicht und lehnt jedes Passwort ab.

  Ohne `pap` lehnt `mschap` auch das richtige Passwort ab; die Probe hat das bestätigt. Ein
  LDAP-Fehler liefert `fail`, das bereits ablehnt (fail closed). Beide Fälle schreiben eine
  eigene Log-Zeile (§ 9).

  Ergebnisse gegen den echten LDAP-Outpost:

  | Fall | Ergebnis |
  |---|---|
  | richtiges Passwort | SUCCESS, MPPE-Schlüssel stimmen |
  | falsches Passwort | FAILURE |
  | Nutzer ohne Hash | FAILURE |
  | radiusd startet bei gestopptem LDAP | startet |
  | LDAP gestoppt, Outpost über IP angesprochen | FAILURE nach etwa 2 s |
  | LDAP zurück, ohne Neustart von radiusd | SUCCESS |
- Der äußere `default`-Server und `proxy-inner-tunnel` bleiben unverändert.

## 7. Ablauf für die Nutzer

| Situation | Ablauf |
|---|---|
| Erstes Einrichten | Portal öffnen, Kachel „WLAN-Zugang“, Passwort wird angezeigt, notieren, bestätigen. |
| Gerät verbinden | SSID wählen, Benutzername und WLAN-Passwort, Zertifikat mit dem angezeigten Namen bestätigen. Android: „Systemzertifikate verwenden“ und Domain eintragen. |
| Passwort vergessen | Neues im Portal holen. Alle Geräte brauchen dann das neue. |
| Gerät verloren | Neues Passwort holen; das alte gilt sofort nicht mehr. |
| Helpdesk | Kann nichts sehen und nichts setzen, nur `wifi-password-nthash` löschen. |
| Austritt | Deaktivieren oder aus der Gruppe nehmen; sofort wirksam. |

## 8. Tests

### 8.1 e2e (CI)

Der RADIUS-Outpost ist in der e2e heute ein FreeRADIUS-Stand-in. Für LDAP kommt ein
Directory-Stand-in dazu, das den Filter aus § 6.4 unverändert auswerten muss, inklusive der
eigenen Attribute `ak-active` und `wifi-password-nthash`. glauth scheidet aus (V7): Es gab die
eigenen Attribute nicht einmal zurück. Das Stand-in ist **OpenLDAP mit einem kleinen
Schema**, das `ak-active`, `wifi-password-nthash` und `memberOf` als gewöhnliche Attribute
definiert. Ein memberOf-Overlay ist für das Stand-in nicht nötig. Vier Nutzer:

| Nutzer | Zustand | Erwartung |
|---|---|---|
| `peapuser` | aktiv, in der Gruppe, Hash gesetzt | Accept mit richtigem Passwort, Reject mit falschem |
| `peapinactive` | `ak-active=FALSE` | Reject |
| `peapnogroup` | nicht in der Gruppe | Reject |
| `peapnohash` | kein `wifi-password-nthash` | Reject |

`eapol_test` prüft beim Accept auch die MSK; eine falsche Schlüsselableitung fällt damit auf.

Weitere Stufen:

- TTLS/PAP-Baseline und VLAN laufen unverändert mit. NAK in beide Richtungen: ein PEAP-Client
  gegen den Standard `ttls` und ein TTLS-Client.
- Kein Reply-Attribut aus dem inneren PEAP-Tunnel im äußeren Accept: Der äußere Accept trägt
  `anonymous`, nicht den inneren Benutzer (das trennt `no` von `yes`).
- LDAP-Stand-in gestoppt: PEAP wird abgelehnt, ohne über das Timeout hinaus zu hängen, TTLS
  geht weiter. Danach wieder gestartet: PEAP geht wieder.
- **freeradius neu gestartet, während LDAP gestoppt ist**: radiusd kommt hoch, TTLS geht, PEAP
  wird abgelehnt.
- LDAP-Stand-in neu erzeugt (feste Adresse): PEAP geht danach wieder, **ohne** dass radiusd
  neu startet.
- `LDAP_HOST` als Name: Der Entrypoint bricht ab.
- Ein zweiter Durchlauf mit `PEAP_ENABLE=false` und ohne LDAP-Variablen: PEAP wird abgelehnt,
  TTLS läuft.
- `radiusd -XC` in `validate` für beide Schalterstellungen.
- Entrypoint lehnt eine DN mit `(` oder `%` ab.

### 8.2 Unit-Test der Policy (CI)

Ein Python-Test liest den Expression-Code aus dem Blueprint und prüft:

- MD4 gegen die Testvektoren aus RFC 1320.
- NT-Hash von `password` = `8846F7EAEE8FB117AD06BDD830B7586C`.
- Passphrase: sechs Wörter, alle aus der Liste.
- Gespeichert wird nur, wenn der Wert aus `prompt_data` dem Session-Wert entspricht.
- Ohne `wifi_ack is True` wird nichts geschrieben.
- Bei einer Exception wird nichts geschrieben.
- Die `base`-Logik: gleiche `base` heißt dieselbe Passphrase, neue `base` heißt eine neue.

### 8.3 Integrationstest gegen echtes authentik (manuell, `workflow_dispatch`)

`test/authentik/run.sh` startet authentik, PostgreSQL und den LDAP-Outpost in der gepinnten
Version (der RADIUS-Outpost gehört nicht zum PEAP-Pfad), spielt den Blueprint ein, führt den Flow per API aus, verbindet per `eapol_test`
(PEAP) und prüft die Fälle aus § 8.1 gegen das echte System. Dazu:

- Ein POST mit verändertem `wifi_password` setzt **nicht** dieses Passwort.
- Das Event-Log enthält den Hash nicht.

Zu schwer für jeden Push, aber Pflicht vor einem Release und nach jedem authentik-Update.

### 8.4 Geräte (manuell, vor Rollout)

Je ein echtes Gerät mit Windows 11, iOS, macOS und Android 13+ verbindet sich ohne Profil.
Ergebnis kommt in `docs/clients.md`.

## 9. Doku

- `docs/authentik.md`: neuer Abschnitt „WLAN-Passwort (PEAP)“: Blueprint einspielen, Kontext,
  Bind-Flow, Servicekonto mit nicht ablaufendem Token und Rotation, Outpost.
- `docs/clients.md`: PEAP ohne Profil pro Plattform, inklusive Zertifikatsbestätigung.
- `docs/migration.md`: der PEAP-Weg geht jetzt ohne AD und ohne `ntlm_auth`; Rollout für
  Bestandsnutzer (Rundmail mit Link, alter Server läuft parallel).
- `README.md`: Sicherheitsabschnitt um den NT-Hash ergänzen; Architekturbild.
- `docs/troubleshooting.md` und `docs/monitoring.md`: neue Log-Zeilen für „kein aktiver
  WLAN-Nutzer mit WLAN-Passwort“, „LDAP nicht erreichbar“ und „LDAP-Bind fehlgeschlagen“.
- Vorlage für die Rundmail an die Nutzer, ohne Site-Daten.

## 10. Sicherheit

- **Der NT-Hash ist passwortäquivalent** für MSCHAPv2. Wer die authentik-Datenbank, einen
  Admin-Account oder das LDAP-Servicekonto hat, hat alle WLAN-Zugänge. Durch das eigene
  WLAN-Passwort nicht mehr den SSO-Zugang.
- **Evil-Twin**: Ohne Profil bestätigen Nutzer das Zertifikat per Klick. Ein gefälschter AP
  bekommt so Challenge und Response; der NT-Hash kostet danach etwa 2^56 DES-Operationen
  offline (§ 5.3). Gegenmittel sind Schulung (angezeigter Zertifikatsname) und auf verwalteten
  Geräten trotzdem ein Profil. Restrisiko, dokumentiert.
- **Klartext in der Session** bis zum Speichern bzw. bis zum Session-Ablauf (§ 5.2).
- **Fremde Adresse für einen gestoppten Outpost** (§ 11a): durch feste Adressen
  ausgeschlossen (§ 6.0); DNS ist nicht mehr im Pfad.
- **Event-Log**: Der Attributname enthält `password`, damit authentik den Wert in Diffs
  schwärzt. V4 und § 8.3 prüfen das.
- **Andere Abflusswege des Hashes**: Admin-UI und -API sowie Blueprint-Exporte zeigen
  `attributes` vollständig. Auch LDAP liefert den Hash breiter als gedacht: authentik gibt
  jedes Benutzerattribut als LDAP-Attribut aus, unabhängig vom Provider. Jeder bestehende
  LDAP-Provider der Instanz (NAS, Nextcloud, …) reicht `wifi-password-nthash` an seine
  suchberechtigten Konten („Search full LDAP directory“) weiter. Der eigene Provider
  `wlan-ldap` ist daher keine Grenze (§ 5.5); vor dem Rollout bestehende LDAP-Provider und
  ihre Servicekonten prüfen und das Recht nur vergeben, wo es nötig ist.
- Der Token `LDAP_BIND_PASSWORD` steht wie die übrigen Secrets in der Compose-Umgebung.

## 11. Prüfergebnisse

Probe am 2026-10-13 gegen authentik 2026.8.3 mit echtem LDAP-Outpost und FreeRADIUS 3.2.10,
Wegwerf-Setup, nichts davon im Repo.

| # | Annahme | Ergebnis |
|---|---|---|
| V1 | Ein Wert überlebt vom Rendern bis zum Absenden | **ja, über die Session** (§ 5.1). Der Prompt-Kontext funktioniert dafür nicht. Read-only-Felder werden beim Absenden serverseitig neu ausgewertet; ein manipulierter POST wird ignoriert. |
| V2 | Validierungs-Policy sieht die Werte und kann abweisen | **ja.** Sie sieht `prompt_data` mit den Serverwerten und lehnt mit Meldung ab. Neu gefunden: Eine Pflicht-Checkbox mit `false` gilt als ausgefüllt, die Policy prüft sie selbst. |
| V3 | Servicekonto bindet mit Token, Token ohne Ablauf | **ja.** Intent `app_password`, `expiring: false`, Bind über eigenen Flow mit Token-Backend. |
| V4 | Kein Event mit dem Hash | **ja.** Weder das Speichern im Flow noch eine Admin-Änderung der Attribute über die API schreibt den Wert in ein Event; ohne Enterprise-Lizenz gibt es keinen Diff. |
| V5 | Attribut mit Bindestrich als LDAP-Attribut und im Filter | **ja.** |
| V6 | Portainer bindet eine zusätzliche Compose-Datei ein | **ja, laut Sekundärquelle**: Git-Stacks haben in CE das Feld „Additional paths“. Beim ersten echten Deploy bestätigen. |
| V7 | glauth als LDAP-Stand-in | **nein.** Eigene Attribute kamen nicht zurück. OpenLDAP mit kleinem Schema (§ 8.1). |
| V8 | Module im Basis-Image | **ja.** `rlm_ldap`, `rlm_mschap`, `rlm_eap_peap`, `rlm_eap_mschapv2`. |

Dazu korrigiert die Probe § 6.4 an zwei Stellen (`Auth-Type inner-eap`, nacktes `mschap`) und
findet § 11a.

## 11a. Gestoppter Outpost, fremde Adresse (entschieden: feste Adressen)

**Befund.** Ist ein Outpost-Container gestoppt, löst Dockers DNS seinen Namen nicht mehr selbst
auf und leitet die Anfrage an den DNS des Hosts weiter. In der Probe kam so eine öffentliche
Adresse zurück: Der Host-Resolver hängte eine Such-Domain an, und die hat einen
Wildcard-Eintrag. Auch ein Punkt am Namensende half nicht. Ob ein Produktionshost das genauso
tut, hängt von seinem Resolver ab. Verlassen kann sich das Design darauf nicht.

Folgen:

- **PEAP (neu):** `rlm_ldap` verbindet sich mit der fremden Adresse und sendet den Bind mit dem
  Servicekonto-Token im Klartext. Nebenbei hängt jeder Verbindungsversuch rund 9 s, und eine
  PEAP-Anfrage dauerte so 21 s statt 2 s.
- **TTLS (bestehender Code, #5):** Der Adress-Watcher sieht eine neue Adresse, startet radiusd
  neu, und der Entrypoint legt radiusd auf die fremde Adresse fest. Access-Requests mit
  PAP-Passwörtern, nur durch das Shared Secret verschleiert, gingen dann an diesen Host. Der
  Befund betrifft also schon den Stand auf `develop`.

**Optionen:**

1. **Feste Adressen (Empfehlung).** Das Compose-Netz `radius` bekommt ein festes Subnetz
   (Variable, mit Standardwert), beide Outposts feste `ipv4_address`. FreeRADIUS spricht sie
   über die IP an. DNS ist aus dem Pfad, der Watcher aus #5 wird überflüssig (eine literale IP
   schaltet ihn heute schon ab), und der LDAP-Ausfall endet nach etwa 2 s. Preis: Das Subnetz
   darf mit nichts am Host kollidieren; das ist eine Variable mehr.
2. **Adressprüfung im Entrypoint.** Nur Adressen aus dem eigenen Docker-Netz des Containers
   werden angenommen, für den RADIUS- wie den LDAP-Outpost. Für LDAP bräuchte es dann wieder
   Auflösen, Festlegen und einen Watcher, also genau das, was Revision 2 gestrichen hat.
3. **LDAPS mit Zertifikatsprüfung.** Schützt den Token, aber nicht den TTLS-Pfad, und braucht
   ein Zertifikat am Provider samt CA-Datei für FreeRADIUS.

**Entscheidung (Christian, 2026-10-13): Option 1, feste Adressen**, umgesetzt in § 6.0. Der
TTLS-Teil ist als #15 erfasst, weil er schon heute gilt.

## 12. Standardwerte für den Blueprint-Kontext

| Schlüssel | Standard |
|---|---|
| `wlan_group` | `wlan` |
| `ldap_search_group` | `wlan-ldap-search` |
| `ssid` | `WLAN` |
| `radius_server_name` | `radius.example.com` |
| `authentik_url` | `https://authentik.example.com` (authentik akzeptiert für die Kachel nur eine absolute `meta_launch_url`) |
| `ldap_base_dn` | `dc=ldap,dc=goauthentik,dc=io` |

## 13. Revisionen

**Revision 2, 2026-10-13, nach einem unabhängigen Review durch OpenAI Codex.**

| Befund | Änderung |
|---|---|
| LDAP-Pool mit `start > 0` und `depends_on: service_healthy` verhindern den Start ohne LDAP; Neustarts durch die bestehenden Watcher hätten auch TTLS mitgerissen | `start = 0`, kein `depends_on` auf LDAP, keine Auflösung beim Start (§ 6.1, § 6.3, § 6.4), neue e2e-Stufe |
| Adress-Watcher für LDAP unnötig, schadet TTLS | gestrichen; libldap löst selbst neu auf (§ 6.3) |
| Zwei Initialwert-Expressions erzeugen zwei Zufallswerte; authentik wertet Read-only-Felder womöglich beim Absenden neu aus | eine Passphrase im Plan-Kontext, nichts vom Client übernommen, HMAC entfällt (§ 5.1, V1) |
| `NT-Password` als 32 ASCII-Zeichen wird von `mschap` verworfen | `pap` in `authorize` normalisiert; Mapping im Modul (§ 6.4) |
| `${…}` statt `$ENV{…}`; DN wird ungeescaped in den Filter gesetzt | `$ENV{}`, enge Zeichenprüfung der DNs (§ 6.3) |
| Module und Sites lassen sich nicht abhängig vom Schalter laden | Include-Dateien unter `/run/radiusd/`, Module außerhalb von `mods-enabled/` (§ 6.3) |
| Fünf Wörter liegen unter dem 2^56-DES-Weg | sechs Wörter, Begründung korrigiert (§ 5.3, § 10) |
| Hash im Event-Diff, weil der Name nicht unter die Bereinigung fällt; Unterstrich ungültig in LDAP-Schemas | Umbenennung in `wifi-password-nthash` (§ 5.2) |
| Klartext liegt im Flow-Plan der Session | offen dokumentiert (§ 5.2, § 10) |
| PEAP könnte innere Reply-Attribute nach außen kopieren | `copy_request_to_tunnel = no`, `use_tunneled_reply = no` (§ 6.4) |
| `mschap`-MPPE-Optionen wirken bei PEAP nicht | gestrichen, Begründung ergänzt (§ 6.4) |
| `default_eap_type = peap` bringt nichts für Zero-Touch und belastet TTLS-Clients | bleibt `ttls` (§ 6.4) |
| Token-Ablauf des Servicekontos, MFA im Bind-Flow | nicht ablaufender Token, eigener Bind-Flow, Log-Zeile (§ 5.5) |
| Policy: Nutzerquelle, Fehlerverhalten, paralleles Überschreiben von `attributes` | `request.user`, `False` ohne Schreiben, `select_for_update` (§ 5.1) |
| Garantie „kein anderer Weg schreibt“ zu stark | auf nutzerbedienbare Wege eingeschränkt (§ 5.2) |

Verworfen: LDAP-Injection über `User-Name`. `rlm_ldap` escaped Werte im `user.filter` selbst;
die Spec verlangt jetzt ausdrücklich, dass der Filter dort steht.

**Revision 3, 2026-10-13, nach der Probe gegen authentik 2026.8.3 (§ 11).**

| Befund | Änderung |
|---|---|
| Schreiben in `prompt_context` überlebt den Request nicht; Read-only-Felder werden beim Absenden neu ausgewertet | Passphrase in der Session mit `base`-Prüfung (§ 5.1) |
| Pflicht-Checkbox mit `false` gilt als ausgefüllt | Policy prüft `wifi_ack is True` (§ 5.1) |
| `inner-eap` verlangt `Auth-Type inner-eap`; `eap_mschapv2` ruft `Auth-Type mschap` | Skizze in § 6.4 korrigiert |
| glauth liefert eigene Attribute nicht | OpenLDAP-Stand-in (§ 8.1) |
| `yo-yo` enthält das Trennzeichen | 1295 Wörter (§ 5.3) |
| Ohne Enterprise kein Event-Diff | § 5.2 präzisiert |
| Gestoppter Outpost löst auf fremde Adresse auf, betrifft auch TTLS | § 11a, Entscheidung offen |

**Revision 4, 2026-10-13.** § 11a entschieden: feste Adressen für beide Outposts (§ 6.0, #15).
`LDAP_HOST` und `AUTHENTIK_RADIUS_HOST` müssen literale IPv4-Adressen sein; der Adress-Watcher
aus #5 entfällt.

Nachtrag beim Schreiben des Plans: Umstieg mit aktuellem Compose geprüft (§ 6.0), Inhalt von
`peap-modules.conf` (§ 6.3), Umfang des Blueprints und Gruppe `wlan-ldap-search` (§ 5).
Die Log-Zeilen sind Englisch wie alle Logs des Stacks; die in § 9 genannten Texte sind ihre
deutsche Bedeutung.

**Revision 5, 2026-10-14, bei der Umsetzung.**

| Befund | Änderung |
|---|---|
| `rejects()` im e2e zählte Abbruch durch `timeout` oder Kill als Ablehnung | prüft den Exit-Status; ein vom Timeout beendeter Container ist keine Ablehnung (Entrypoint-Stufen zu `AUTHENTIK_RADIUS_HOST`, `LDAP_HOST`) |
| busybox-`grep -E` lehnt `{1,256}` ab (`RE_DUP_MAX` 255) | DN-Länge 1 bis 255 (§ 6.3) |
| Gegenprobe zu `use_tunneled_reply` schlug nicht an: `MS-CHAP2-Success` entfernt `eap_mschapv2` selbst | e2e prüft die äußere Identität `anonymous` statt des inneren Benutzers (§ 6.4, § 8.1) |
| e2e band nur `peapinactive` an die Log-Zeile des Verzeichnisses | alle drei Sperrgründe (`peapinactive`, `peapnogroup`, `peapnohash`) müssen die Zeile erzeugen (§ 8.1) |
| Compose-Prüfung akzeptierte jede Ablehnung | der Render ohne `AUTHENTIK_LDAP_TOKEN` muss scheitern und die Variable nennen (§ 6.1) |
| Blueprint wird byteweise verglichen, CRLF bricht den Test | `.gitattributes` erzwingt LF für `authentik/**` und `test/authentik/**` |
| authentik lehnt eine relative `meta_launch_url` ab („Enter a valid URL“) | Kontext-Schlüssel `authentik_url` (§ 5, § 12) |
| Integrationstest scheiterte früh (403, `invalidation_flow` leer) | wartet vor dem Import auf authentiks eigene Blueprints; Abweisungen müssen ein Access-Reject mit dem richtigen Grund sein; Event-Log-Prüfung mit Positivkontrolle und Paginierung; Absenden ohne Bestätigung darf den gespeicherten Hash nicht ändern (§ 8.3) |
| Veralteter Tab speicherte eine nie angezeigte Passphrase (gegen echtes authentik bestätigt) | Erzeugen nur beim Rendern (GET); POST ohne passenden Session-Wert ergibt `""`, die Policy lehnt als abgelaufen ab (§ 5.1) |
| Abschluss-Review: Der Hash ist über jeden LDAP-Provider der Instanz lesbar, nicht nur über `wlan-ldap`; authentik liefert jedes Benutzerattribut als LDAP-Attribut | § 10 korrigiert: der eigene Provider ist keine Grenze; vor dem Rollout bestehende LDAP-Provider und ihre Servicekonten prüfen, „Search full LDAP directory“ nur wo nötig (auch `docs/authentik.md` § 6, README) |
