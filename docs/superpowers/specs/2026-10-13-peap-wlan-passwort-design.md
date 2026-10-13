# Design: PEAP-MSCHAPv2 mit eigenem, generiertem WLAN-Passwort aus authentik

Datum: 2026-10-13
Status: Entwurf, Review ausstehend
Issue: #14 (Spike-Ergebnis dort). Bezug: #11, #7/#12 (für dieses Ziel zurückgestellt), #8

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
- Bestehende TTLS/PAP-Clients funktionieren unverändert weiter.
- Eine Bestandsinstallation ohne die neue Option verhält sich exakt wie heute.

## 2. Entscheidungen (mit Christian abgestimmt)

| Frage | Entscheidung |
|---|---|
| Methode | PEAP-MSCHAPv2 zero-touch (Option B). TTLS/PAP + Onboarding-Seite (Option A) ist ein späterer Umbau. |
| WLAN-Passwort = SSO-Passwort? | **Nein.** Eigenes WLAN-Passwort, getrennt vom SSO-Passwort. |
| Wer wählt das Passwort? | **authentik erzeugt es.** Der Nutzer sieht es einmalig. |

Das eigene Passwort löst den Haupt-Befund des Spikes: Ein Admin-Reset des SSO-Passworts ließ
dort den alten NT-Hash stehen. Mit getrennten Passwörtern berührt ein SSO-Reset das WLAN
nicht, und es gibt genau **einen** Weg, der den Hash schreibt.

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
                         (prüft MSCHAPv2       (liefert wifi_nt_hash nur für aktive
                          gegen NT-Hash)        Mitglieder der WLAN-Gruppe)

Nutzer ──Browser──▶ authentik-Flow „WLAN-Passwort“ ──schreibt──▶ user.attributes.wifi_nt_hash
```

Drei Teile mit je einer Aufgabe:

1. **authentik-Konfiguration** (Blueprint im Repo): Flow, der ein Passwort erzeugt und den
   NT-Hash speichert; Anwendung als Kachel; LDAP-Provider samt Servicekonto.
2. **LDAP-Outpost** als dritter Container, nur im Docker-Netz erreichbar.
3. **FreeRADIUS**: zusätzlich `peap`, `mschap` und `ldap`, hinter einem Schalter.

## 5. authentik

Alles in diesem Abschnitt liefert ein Blueprint `authentik/blueprints/wlan-passwort.yaml`.
Die Werte, die pro Installation abweichen (Gruppenname, Servername des Zertifikats, SSID),
kommen als Blueprint-Kontext; Standardwerte stehen in § 12.

### 5.1 Flow „WLAN-Passwort“

- Slug `wlan-passwort`, Designation `stage_configuration`, Authentication
  `require_authenticated`.
- Flow-Policy-Binding: Mitglied der WLAN-Gruppe. Wer nicht Mitglied ist, wird abgewiesen.
- **Eine** Prompt-Stage `wlan-passwort-anzeige` mit diesen Feldern:

| Feld | Typ | Inhalt |
|---|---|---|
| `wifi_password` | `text_read_only` | Initialwert per Expression: neu erzeugte Passphrase (§ 5.3) |
| `wifi_password_mac` | `hidden` | Initialwert per Expression: HMAC über User-PK und Passphrase |
| `wifi_info` | `static` | SSID, Benutzername, erwarteter Zertifikatsname, Hinweis „wird nur jetzt angezeigt“ |
| `wifi_ack` | `checkbox`, Pflicht | „Ich habe das Passwort notiert. Das bisherige WLAN-Passwort wird damit ungültig.“ |

- **Validierungs-Policy** `wlan-passwort-speichern` an der Prompt-Stage. Sie läuft beim
  Absenden, sieht `prompt_data` und ist damit der Anker, den der Spike mit einer Dummy-Stage
  nachbauen musste. Sie:
  1. prüft den HMAC. Schlägt er fehl, lehnt sie ab: Der Client hat das angezeigte
     Passwort ersetzt.
  2. berechnet den NT-Hash, `MD4(UTF-16LE(passwort))`, mit der eingebetteten MD4
     (authentik hat kein MD4, OpenSSL 3).
  3. speichert `attributes.wifi_nt_hash` (32 Hex-Zeichen, Großbuchstaben) und
     `attributes.wifi_password_set_at` (ISO-8601, UTC) direkt über das ORM:
     `User.objects.get(pk=...)`, `save(update_fields=["attributes"])`. Policies laufen in
     einem eigenen Prozess, deshalb nicht über `request.user` (Spike-Befund).
  4. gibt `True` zurück. Der Flow endet und leitet zur Bibliothek.

Erzeugen beim Anzeigen, Speichern erst beim Absenden: Lädt der Nutzer die Seite neu oder bricht
ab, bleibt das bisherige WLAN-Passwort gültig.

Der HMAC-Schlüssel ist Djangos `SECRET_KEY` mit einem festen Kontext-Präfix
(`authentik-freeradius/wifi-password/v1`). Ohne HMAC könnte ein Nutzer per manipuliertem POST
ein selbst gewähltes Passwort setzen und die Entscheidung „erzeugt“ umgehen.

### 5.2 Gespeicherte Daten

| Attribut | Inhalt | Wer schreibt |
|---|---|---|
| `wifi_nt_hash` | NT-Hash, 32 Hex-Zeichen | nur die Policy aus § 5.1 |
| `wifi_password_set_at` | Zeitpunkt der Erzeugung | nur die Policy aus § 5.1 |

Der Klartext wird nirgends gespeichert. Löschen von `wifi_nt_hash` sperrt den WLAN-Zugang des
Nutzers, bis er ein neues Passwort holt.

Kein anderer Weg darf diese Attribute schreiben. Der Standard-User-Settings-Flow schreibt keine
`attributes.*`-Felder; der Blueprint ändert ihn nicht, und die Doku sagt, dass ein Prompt
mit Feldnamen `attributes.wifi_*` in einem nutzerbedienbaren Flow diese Garantie bricht.

### 5.3 Passphrase

- Fünf Wörter aus der **EFF Short Wordlist 1** (1296 Wörter, CC BY 3.0), mit Bindestrich
  getrennt, Kleinbuchstaben. Beispiel: `acorn-tulip-gravy-mango-swift`.
- Entropie 5 × log2(1296) ≈ 51,7 Bit. Zufall aus `secrets.choice`.
- Kurze, gängige Wörter ohne Umlaute, damit das Tippen am Handy klappt. Englisch ist der Preis
  für eine fertig lizenzierte Liste; eine deutsche Liste kann später die Datei ersetzen.

Warum die Stärke hier zählt, aber nicht unbegrenzt: Ein Evil-Twin, der einen MSCHAPv2-Austausch
mitschneidet, kommt per DES-Angriff (2^56) unabhängig von der Passwortstärke an den NT-Hash, und
der Hash reicht für den WLAN-Zugang. Die Passwortstärke schützt den **Klartext** (der dank
Generierung nirgends sonst gilt) und gegen Online-Raten. Mehr als ~50 Bit kaufen hier nichts.

### 5.4 Anwendung „WLAN-Zugang“

- Anwendung ohne Provider, Launch-URL `/if/flow/wlan-passwort/`.
- Policy-Binding: WLAN-Gruppe. Nur Mitglieder sehen die Kachel.

### 5.5 LDAP-Provider und Servicekonto

- Eigener LDAP-Provider `wlan-ldap` mit eigener Anwendung, ausschließlich für FreeRADIUS. Die
  Doku warnt: Dieser Provider gibt NT-Hashes heraus und darf nicht für andere Anwendungen
  wiederverwendet werden.
- Search-Mode `direct`, Bind-Mode `direct`. `cached` würde Deaktivierungen verzögern.
- Servicekonto `svc-wlan-ldap` (Typ Service Account), Rolle mit der Permission
  `search_full_directory` auf diesem Provider. Bind mit dem Token des Kontos als Passwort.
- Die Anwendung des Providers ist nur an das Servicekonto gebunden; normale Nutzer können sich
  dort nicht binden.

## 6. Stack

### 6.1 Compose

- Neue Datei `docker-compose.peap.yml`, in Portainer als zusätzliche Compose-Datei
  eingebunden. Sie fügt hinzu:
  - Dienst `authentik_ldap`, `ghcr.io/goauthentik/ldap:${AUTHENTIK_VERSION}`, eigener
    Outpost-Token `AUTHENTIK_LDAP_TOKEN`, kein veröffentlichter Port, Netz `radius`. Der
    eingebaute Healthcheck des Images bleibt, wie beim RADIUS-Outpost.
  - für `freeradius`: `depends_on: authentik_ldap: service_healthy` und die LDAP-Variablen.
- Ohne die Zusatzdatei ändert sich nichts.

### 6.2 Neue Variablen

| Variable | Pflicht bei PEAP | Bedeutung |
|---|---|---|
| `PEAP_ENABLE` | – | `true` schaltet PEAP ein. Standard `false`. |
| `LDAP_HOST` | ja | Standard `authentik_ldap` |
| `LDAP_PORT` | – | Standard `3389` (Klartext-Port des Outposts) |
| `LDAP_BASE_DN` | ja | Base-DN des Providers, z. B. `dc=ldap,dc=goauthentik,dc=io` |
| `LDAP_BIND_DN` | ja | DN des Servicekontos |
| `LDAP_BIND_PASSWORD` | ja | Token des Servicekontos |
| `LDAP_WLAN_GROUP_DN` | ja | DN der WLAN-Gruppe |

LDAP ohne TLS im privaten Docker-Netz, so wie heute PAP zum RADIUS-Outpost. Das Bedrohungsmodell
ist dasselbe: Wer den Host hat, sieht ohnehin alles. README und Doku sagen das.

### 6.3 entrypoint.sh

- `PEAP_ENABLE` ist `true` oder `false`, sonst Abbruch mit Meldung.
- Bei `true`: Pflichtvariablen prüfen; Abbruch mit Meldung, wenn eine fehlt. DNs nur aus
  druckbaren Zeichen ohne Zeilenumbruch, weil sie in die Konfiguration geschrieben werden.
- `LDAP_HOST` wird aufgelöst und überwacht wie `AUTHENTIK_RADIUS_HOST` (#5): gleiche Funktion,
  gleiches `OUTPOST_RESOLVE_INTERVAL`, gleiche Log-Zeile mit dem Hostnamen.
- Bei `true` aktiviert das Skript die PEAP-Teile, bei `false` bleiben sie aus. Umgesetzt über
  erzeugte Include-Dateien unter `/run/radiusd/`, nach dem Muster von `vlan-map.conf`. Das
  Dateisystem ist read-only, die Konfiguration im Image bleibt unverändert.

### 6.4 FreeRADIUS

- **`mods/eap`**: zusätzlicher `peap`-Block (`tls = tls-common`, `default_eap_type = mschapv2`,
  `virtual_server = "peap-inner-tunnel"`), nur bei `PEAP_ENABLE=true` eingebunden.
  `default_eap_type` des äußeren EAP wird bei aktivem PEAP `peap`: Clients ohne Profil
  probieren meist PEAP zuerst, TTLS-Clients mit Profil antworten mit NAK und bekommen TTLS. Die
  e2e prüft beide.
- **Neuer Virtual Server `peap-inner-tunnel`**, getrennt von `proxy-inner-tunnel`:
  - `authorize`: `inner-eap` (EAP-MSCHAPv2), dann `ldap`. Der Filter verlangt alles auf
    einmal: `(&(cn=%{User-Name})(ak-active=TRUE)(memberOf=${LDAP_WLAN_GROUP_DN})(wifi_nt_hash=*))`.
    Das `ldap`-Modul escaped `User-Name` im Filter selbst.
  - Treffer: `control:NT-Password := wifi_nt_hash`. Kein Treffer: Reject ohne Reply-Message an den
    Client und mit dem Log-Eintrag „kein aktiver WLAN-Nutzer mit WLAN-Passwort“.
  - `authenticate`: `Auth-Type MS-CHAP { mschap }`, `Auth-Type eap { inner-eap }`.
  - LDAP nicht erreichbar oder Fehler: Reject (fail closed), eigener Log-Text.
- **`mods/mschap`**: `use_mppe = yes`, `require_encryption = yes`, `require_strong = yes`,
  kein `ntlm_auth`.
- **`mods/ldap`**: Server, Bind und Base aus den Variablen, kein Gruppen-Caching, kurze
  Timeouts (Verbindung 3 s, Abfrage 3 s), damit ein hängender Outpost nicht den EAP-Austausch
  der AP überdauert.
- Der äußere `default`-Server bleibt unverändert; `eap` behandelt PEAP selbst.

## 7. Ablauf für die Nutzer

| Situation | Ablauf |
|---|---|
| Erstes Einrichten | Portal öffnen, Kachel „WLAN-Zugang“, Passwort wird angezeigt, notieren, bestätigen. |
| Gerät verbinden | SSID wählen, Benutzername und WLAN-Passwort, Zertifikat mit dem angezeigten Namen bestätigen. Android: „Systemzertifikate verwenden“ und Domain eintragen. |
| Passwort vergessen | Neues im Portal holen. Alle Geräte brauchen dann das neue. |
| Gerät verloren | Neues Passwort holen; das alte gilt sofort nicht mehr. |
| Helpdesk | Kann nichts sehen und nichts setzen, nur `wifi_nt_hash` löschen. |
| Austritt | Deaktivieren oder aus der Gruppe nehmen; sofort wirksam. |

## 8. Tests

### 8.1 e2e (CI)

Der RADIUS-Outpost ist in der e2e heute ein FreeRADIUS-Stand-in. Für LDAP kommt ein
**glauth**-Stand-in dazu, weil glauth eigene Attribute und `memberOf` aus einer Konfigurations-
datei liefert, ohne Schema-Arbeit. Er stellt vier Nutzer bereit:

| Nutzer | Zustand | Erwartung |
|---|---|---|
| `peapuser` | aktiv, in der Gruppe, Hash gesetzt | Accept mit richtigem Passwort, Reject mit falschem |
| `peapinactive` | `ak-active=FALSE` | Reject |
| `peapnogroup` | nicht in der Gruppe | Reject |
| `peapnohash` | kein `wifi_nt_hash` | Reject |

Weitere Stufen:

- TTLS/PAP-Baseline und VLAN laufen unverändert mit; der Server schlägt jetzt PEAP vor, TTLS
  muss über NAK weiter funktionieren.
- LDAP-Stand-in gestoppt: PEAP wird abgelehnt (keine Hänger über das Timeout hinaus), TTLS geht
  weiter. Danach wieder gestartet: PEAP geht wieder.
- LDAP-Stand-in neu erzeugt mit neuer Adresse: der Watcher aus § 6.3 greift.
- Ein zweiter Durchlauf mit `PEAP_ENABLE=false` prüft, dass PEAP abgelehnt wird und TTLS
  läuft.
- `radiusd -XC` in `validate` für beide Schalterstellungen.

### 8.2 Unit-Test der Policy (CI)

Ein Python-Test liest den Expression-Code aus dem Blueprint und prüft:

- MD4 gegen die Testvektoren aus RFC 1320.
- NT-Hash von `password` = `8846F7EAEE8FB117AD06BDD830B7586C`.
- Passphrase-Format und Wörter aus der Liste.
- HMAC: manipuliertes Passwort wird abgelehnt.

### 8.3 Integrationstest gegen echtes authentik (manuell, `workflow_dispatch`)

`test/authentik/run.sh` startet authentik, PostgreSQL und beide Outposts in der gepinnten
Version, spielt den Blueprint ein, führt den Flow per API aus, verbindet per `eapol_test`
(PEAP) und prüft die Fälle aus § 8.1 gegen das echte System. Zu schwer für jeden Push, aber
Pflicht vor einem Release und nach jedem authentik-Update.

### 8.4 Geräte (manuell, vor Rollout)

Je ein echtes Gerät mit Windows 11, iOS, macOS und Android 13+ verbindet sich ohne Profil.
Ergebnis kommt in `docs/clients.md`.

## 9. Doku

- `docs/authentik.md`: neuer Abschnitt „WLAN-Passwort (PEAP)“: Blueprint einspielen, Kontext,
  Servicekonto, Outpost.
- `docs/clients.md`: PEAP ohne Profil pro Plattform, inklusive Zertifikatsbestätigung.
- `docs/migration.md`: der PEAP-Weg geht jetzt ohne AD und ohne `ntlm_auth`; Rollout für
  Bestandsnutzer (Rundmail mit Link, alter Server läuft parallel).
- `README.md`: Sicherheitsabschnitt um den NT-Hash ergänzen; Architekturbild.
- `docs/troubleshooting.md` und `docs/monitoring.md`: neue Log-Zeilen.
- Vorlage für die Rundmail an die Nutzer, ohne Site-Daten.

## 10. Sicherheit

- **Der NT-Hash ist passwortäquivalent** für MSCHAPv2. Wer die authentik-Datenbank, einen
  Admin-Account oder das LDAP-Servicekonto hat, hat alle WLAN-Zugänge. Durch das eigene
  WLAN-Passwort nicht mehr den SSO-Zugang.
- **Evil-Twin**: Ohne Profil bestätigen Nutzer das Zertifikat per Klick. Ein gefälschter AP
  bekommt so den NT-Hash. Gegenmittel sind Schulung (angezeigter Zertifikatsname) und auf
  verwalteten Geräten trotzdem ein Profil. Restrisiko, dokumentiert.
- Event-Log von authentik: Es ist zu prüfen, dass die Speicherung keinen Event mit dem Hash im
  Klartext erzeugt (§ 11).
- Der Token `LDAP_BIND_PASSWORD` steht wie die übrigen Secrets in der Compose-Umgebung.

## 11. Vor dem Plan zu verifizieren

Kurze Proben gegen echtes authentik 2026.8.3. Fällt eine durch, steht die Ausweichlösung
daneben.

| # | Annahme | Ausweichlösung |
|---|---|---|
| V1 | Initialwerte per Expression an `text_read_only` und `hidden` werden pro Anzeige einmal ausgewertet, und die beiden Felder sehen **dieselbe** Passphrase | Passphrase und HMAC in **einem** Hidden-Feld als `passphrase.hmac`, Anzeige über ein `static`-Feld, das denselben Wert rendert |
| V2 | Validierungs-Policies einer Prompt-Stage sehen `prompt_data` inklusive Read-only- und Hidden-Feldern | Policy an einer Folge-Stage (Spike-Weg), dann mit einer Stage ohne sichtbaren Schritt |
| V3 | `SECRET_KEY` ist im Expression-Kontext lesbar | eigener Schlüssel als Blueprint-Kontext |
| V4 | Speichern über das ORM erzeugt keinen Event mit dem Hash | Speichern über `QuerySet.update()` statt `save()`, das keine Model-Signale auslöst; sonst Event-Retention kurz halten und dokumentieren |
| V5 | Servicekonto bindet mit seinem Token am LDAP-Outpost | App-Passwort-Token |
| V6 | Portainer bindet eine zusätzliche Compose-Datei bei Git-Stacks ein | Compose-Profile (`COMPOSE_PROFILES`) |
| V7 | glauth liefert `ak-active`, `memberOf` und eigene Attribute so, dass derselbe Filter wie gegen authentik greift | OpenLDAP mit kleinem Schema |

## 12. Standardwerte für den Blueprint-Kontext

| Schlüssel | Standard |
|---|---|
| `wlan_group` | `wlan` |
| `ssid` | `WLAN` |
| `radius_server_name` | `radius.example.com` |
