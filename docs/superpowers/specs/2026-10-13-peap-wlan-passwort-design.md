# Design: PEAP-MSCHAPv2 mit eigenem, generiertem WLAN-Passwort aus authentik

Datum: 2026-10-13
Status: Entwurf, Revision 2 nach Codex-Review (§ 13), Freigabe ausstehend
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

Alles in diesem Abschnitt liefert ein Blueprint `authentik/blueprints/wlan-passwort.yaml`.
Die Werte, die pro Installation abweichen (Gruppenname, Servername des Zertifikats, SSID),
kommen als Blueprint-Kontext; Standardwerte stehen in § 12.

### 5.1 Flow „WLAN-Passwort“

- Slug `wlan-passwort`, Designation `stage_configuration`, Authentication
  `require_authenticated`.
- Flow-Policy-Binding: Mitglied der WLAN-Gruppe. Wer nicht Mitglied ist, wird abgewiesen.

**Grundsatz: Pro Flow-Durchlauf gibt es genau eine Passphrase, und sie liegt nur auf dem
Server.** Anzeige und Speichern leiten sich aus diesem einen Wert ab. Nichts, was der Browser
zurückschickt, bestimmt das gespeicherte Passwort. Damit braucht es keinen HMAC, und ein
manipulierter POST kann kein selbst gewähltes Passwort setzen.

Ablauf:

1. **Erzeugen.** Beim ersten Anzeigen der Prompt-Stage wird die Passphrase erzeugt und im
   Flow-Plan-Kontext unter `wifi_password_pending` abgelegt. Ist der Schlüssel schon gesetzt
   (erneutes Rendern derselben Stage), wird er wiederverwendet. Der konkrete Mechanismus ist
   Prüfpunkt V1 (§ 11).
2. **Anzeigen.** Prompt-Stage `wlan-passwort-anzeige`:

   | Feld | Typ | Inhalt |
   |---|---|---|
   | `wifi_password` | `text_read_only` | der Wert aus `wifi_password_pending` |
   | `wifi_info` | `static` | SSID, Benutzername, erwarteter Zertifikatsname, Hinweis „wird nur jetzt angezeigt“ |
   | `wifi_ack` | `checkbox`, Pflicht | „Ich habe das Passwort notiert. Das bisherige WLAN-Passwort wird damit ungültig.“ |

3. **Speichern.** Eine Validierungs-Policy `wlan-passwort-speichern` an der Prompt-Stage läuft
   beim Absenden. Sie liest die Passphrase aus `wifi_password_pending`, **nicht** aus
   `prompt_data`, und:
   1. bestimmt den Nutzer aus `request.user` (der Flow verlangt eine Anmeldung);
   2. berechnet den NT-Hash, `MD4(UTF-16LE(passwort))`, mit der eingebetteten MD4
      (authentik hat kein MD4, OpenSSL 3);
   3. schreibt in einer Transaktion mit `select_for_update()` auf den frisch gelesenen
      Nutzer nur die beiden Schlüssel aus § 5.2 und speichert mit
      `save(update_fields=["attributes"])`. So überschreibt sie keinen parallelen
      Schreibvorgang auf andere Attribute.
   4. entfernt `wifi_password_pending` aus dem Plan-Kontext, soweit der Mechanismus aus V1
      das zulässt;
   5. gibt `True` zurück. Bei jeder Exception gibt sie `False` zurück und schreibt nichts.

   Der Flow endet und leitet zur Bibliothek.

Erzeugen beim Anzeigen, Speichern erst beim Absenden: Bricht der Nutzer ab, bleibt das
bisherige WLAN-Passwort gültig.

Im Spike lief eine Policy in einem eigenen Prozess, deshalb schreibt sie über das ORM und nicht
über das `request.user`-Objekt. Das ist eine Beobachtung aus dem Spike, keine Garantie;
authentik führt Policies je nach Worker auch im selben Prozess aus. Das Design funktioniert in
beiden Fällen, V1 muss es aber für den Plan-Kontext belegen.

**Ausweichlösung, falls V1 keinen Weg findet, einen Wert serverseitig über das Absenden zu
halten:** Erzeugen und Speichern fallen zusammen. Die Expression, die das Passwort erzeugt,
schreibt den Hash sofort; die Checkbox ist nur noch Bestätigung. Preis: Wer die Seite öffnet
und abbricht, hat sein altes WLAN-Passwort trotzdem verloren. Der Hinweistext sagt das.

### 5.2 Gespeicherte Daten

| Attribut | Inhalt | Wer schreibt |
|---|---|---|
| `wifi-password-nthash` | NT-Hash, 32 Hex-Zeichen, Großbuchstaben | nur die Policy aus § 5.1 |
| `wifi-password-set-at` | Zeitpunkt der Erzeugung, ISO 8601, UTC | nur die Policy aus § 5.1 |

Zu den Namen:

- Der Bindestrich macht die Namen zu gültigen LDAP-Attributnamen (RFC 4512 erlaubt keinen
  Unterstrich). Das braucht das Test-Directory (§ 8.1); authentik reicht den Schlüssel laut
  Spike unverändert durch.
- `password` im Namen sorgt dafür, dass authentiks Bereinigung (`PASS` im Schlüssel) den Wert
  in Event-Diffs schwärzt. V4 prüft das.

Der Hash ist die einzige dauerhafte Ablage. Die Passphrase steht kurz im Klartext im
Flow-Plan, also in der Session, und Sessions liegen in PostgreSQL. Sie verschwindet mit dem
Ende des Flows oder spätestens mit dem Ablauf der Session; bis dahin ist sie auch in
DB-Backups denkbar. Das ist vertretbar, weil die Passphrase nirgends sonst gilt.

Löschen von `wifi-password-nthash` sperrt den WLAN-Zugang des Nutzers, bis er ein neues
Passwort holt.

Kein **nutzerbedienbarer** Weg außer diesem Flow darf diese Attribute schreiben. Admins können
`attributes` in UI und API jederzeit ändern; das ist gewollt (Helpdesk löscht). Prompt-Stages
schreiben nur deklarierte Felder. Die Doku sagt, dass ein Prompt mit Feldnamen
`attributes.wifi-password-*` in einem nutzerbedienbaren Flow diese Garantie bricht.

### 5.3 Passphrase

- **Sechs** Wörter aus der **EFF Short Wordlist 1** (1296 Wörter, CC BY 3.0), mit
  Bindestrich getrennt, Kleinbuchstaben. Beispiel: `acorn-tulip-gravy-mango-swift-ample`.
- Entropie 6 × log2(1296) ≈ 62 Bit. Zufall aus `secrets.choice`.
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
- Servicekonto `svc-wlan-ldap` (Typ Service Account), Rolle mit der Permission
  `search_full_directory` auf diesem Provider. Bind mit einem App-Passwort-Token des Kontos.
  Der Token läuft **nicht** ab, weil ein abgelaufener Token PEAP leise abschaltet. Rotation ist
  ein dokumentierter, manueller Schritt; ein fehlschlagender Bind erzeugt eine eigene Log-Zeile
  (§ 9), die das Monitoring auswertet.
- Die Anwendung des Providers ist nur an das Servicekonto gebunden; normale Nutzer können sich
  dort nicht binden.

## 6. Stack

### 6.1 Compose

- Neue Datei `docker-compose.peap.yml`, in Portainer als zusätzliche Compose-Datei
  eingebunden. Sie fügt hinzu:
  - Dienst `authentik_ldap`, `ghcr.io/goauthentik/ldap:${AUTHENTIK_VERSION}`, eigener
    Outpost-Token `AUTHENTIK_LDAP_TOKEN`, kein veröffentlichter Port, Netz `radius`. Der
    eingebaute Healthcheck des Images bleibt, wie beim RADIUS-Outpost.
  - für `freeradius`: die LDAP-Variablen und `PEAP_ENABLE=true`. **Kein**
    `depends_on: service_healthy` auf `authentik_ldap`: TTLS darf nicht auf LDAP warten. Ein
    PEAP-Login kurz nach dem Deploy scheitert, bis der LDAP-Outpost bereit ist.
- Ohne die Zusatzdatei ändert sich nichts.

### 6.2 Neue Variablen

| Variable | Pflicht bei PEAP | Bedeutung |
|---|---|---|
| `PEAP_ENABLE` | – | `true` schaltet PEAP ein. Standard `false`. |
| `LDAP_HOST` | – | Standard `authentik_ldap` |
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
- Die drei DNs müssen auf `^[A-Za-z0-9=,._ -]{1,256}$` passen, sonst Abbruch. Sie landen
  ungeescaped in der Konfiguration und im LDAP-Filter (`$ENV{}` wird beim Parsen eingesetzt,
  vor dem Escaping des Moduls). Ausgeschlossen sind damit `( ) * \ %`, Anführungszeichen,
  NUL und Zeilenumbrüche. authentik-Gruppennamen mit anderen Zeichen brauchen einen anderen
  Gruppennamen.
- `LDAP_HOST` wird **nicht** beim Start aufgelöst und **nicht** überwacht. Der Watcher aus #5
  existiert, weil radiusd die Adresse eines `home_server` einmal beim Start festlegt.
  `rlm_ldap` gibt dagegen eine URI an libldap, das beim Verbindungsaufbau neu auflöst, und der
  Pool verbindet nach Fehlern neu. Ein Watcher würde bei jeder Adressänderung des
  LDAP-Outposts radiusd neu starten und damit TTLS-Sitzungen abreißen, ohne etwas zu gewinnen.
- Schaltmechanismus nach dem Muster von `vlan-map.conf`: Das Skript schreibt drei Dateien
  unter `/run/radiusd/`. Bei `true` enthält jede ein `$INCLUDE` auf eine Datei im Image, bei
  `false` ist sie leer:

  | Datei | eingebunden in | enthält bei `true` |
  |---|---|---|
  | `peap-modules.conf` | `radiusd.conf`, Block `modules {}` | `ldap`, `mschap`, `inner-eap` aus `/etc/raddb/peap/` |
  | `peap-eap.conf` | `mods/eap`, Block `eap {}` | den `peap {}`-Block |
  | `peap-site.conf` | `radiusd.conf`, nach `sites-enabled/` | den Server `peap-inner-tunnel` |

  Die Module liegen im Image unter `/etc/raddb/peap/`, **nicht** in `mods-enabled/`; sonst
  würde `ldap` auch bei `false` instanziiert. Das Dateisystem bleibt read-only.

### 6.4 FreeRADIUS

Basis-Image `freeradius/freeradius-server:3.2.10-alpine` bringt `rlm_ldap`, `rlm_mschap`,
`rlm_eap_peap` und `rlm_eap_mschapv2` mit (geprüft).

- **`peap {}`** in `eap`: `tls = tls-common`, `default_eap_type = mschapv2`,
  `virtual_server = "peap-inner-tunnel"`, `copy_request_to_tunnel = no`,
  `use_tunneled_reply = no`. Innere Reply-Attribute verlassen den Tunnel nicht; das passt zum
  Nicht-Ziel „kein VLAN für PEAP“.
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
- **Neuer Virtual Server `peap-inner-tunnel`**, getrennt von `proxy-inner-tunnel`:

  ```
  authorize {
      inner-eap { ok = return }    # EAP-Runden ohne Antwort-Daten
      ldap
      if (notfound) { reject }     # kein aktiver WLAN-Nutzer mit WLAN-Passwort
      pap                          # normalisiert NT-Password: 32 Hex-Zeichen → 16 Bytes
  }
  authenticate {
      Auth-Type eap     { inner-eap }
      Auth-Type MS-CHAP { mschap }
  }
  ```

  Skizze, nicht wörtlich. Ohne `pap` stünden 32 ASCII-Bytes in `NT-Password`, und `mschap`
  verwürfe den Wert. Ein LDAP-Fehler liefert `fail`, das bereits ablehnt (fail closed). Beide
  Fälle schreiben eine eigene Log-Zeile (§ 9).
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
eigenen Attribute `ak-active` und `wifi-password-nthash`. Ob glauth das kann oder OpenLDAP mit
einem kleinen Schema nötig ist, klärt V7. Vier Nutzer:

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
- Kein Reply-Attribut aus dem inneren PEAP-Tunnel im äußeren Accept.
- LDAP-Stand-in gestoppt: PEAP wird abgelehnt, ohne über das Timeout hinaus zu hängen, TTLS
  geht weiter. Danach wieder gestartet: PEAP geht wieder.
- **freeradius neu gestartet, während LDAP gestoppt ist**: radiusd kommt hoch, TTLS geht, PEAP
  wird abgelehnt.
- LDAP-Stand-in neu erzeugt mit neuer Adresse: PEAP geht danach wieder, **ohne** dass radiusd
  neu startet.
- Ein zweiter Durchlauf mit `PEAP_ENABLE=false` und ohne LDAP-Variablen: PEAP wird abgelehnt,
  TTLS läuft.
- `radiusd -XC` in `validate` für beide Schalterstellungen.
- Entrypoint lehnt eine DN mit `(` oder `%` ab.

### 8.2 Unit-Test der Policy (CI)

Ein Python-Test liest den Expression-Code aus dem Blueprint und prüft:

- MD4 gegen die Testvektoren aus RFC 1320.
- NT-Hash von `password` = `8846F7EAEE8FB117AD06BDD830B7586C`.
- Passphrase: sechs Wörter, alle aus der Liste.
- Gespeichert wird der Wert aus dem Plan-Kontext, nicht aus `prompt_data`.
- Bei einer Exception wird nichts geschrieben.

### 8.3 Integrationstest gegen echtes authentik (manuell, `workflow_dispatch`)

`test/authentik/run.sh` startet authentik, PostgreSQL und beide Outposts in der gepinnten
Version, spielt den Blueprint ein, führt den Flow per API aus, verbindet per `eapol_test`
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
- **Klartext in der Session** bis Flow-Ende bzw. Session-Ablauf (§ 5.2).
- **Event-Log**: Der Attributname enthält `password`, damit authentik den Wert in Diffs
  schwärzt. V4 und § 8.3 prüfen das.
- **Andere Abflusswege des Hashes**: Admin-UI und -API sowie Blueprint-Exporte zeigen
  `attributes` vollständig. Der LDAP-Provider ist nur dem Servicekonto zugänglich (§ 5.5).
- Der Token `LDAP_BIND_PASSWORD` steht wie die übrigen Secrets in der Compose-Umgebung.

## 11. Vor dem Plan zu verifizieren

Kurze Proben gegen echtes authentik 2026.8.3. Fällt eine durch, steht die Ausweichlösung
daneben.

| # | Annahme | Ausweichlösung |
|---|---|---|
| V1 | Ein Wert lässt sich beim Anzeigen der Prompt-Stage einmal im Flow-Plan-Kontext ablegen und ist beim Absenden in der Validierungs-Policy lesbar. Kandidaten in dieser Reihenfolge: (a) die `initial_value_expression` von `wifi_password` legt den Wert in `prompt_context` bzw. im Plan ab und gibt ihn bei erneutem Rendern wieder; (b) eine Policy an der Stage-Binding mit `evaluate_on_plan` schreibt in `context["flow_plan"].context`. Zu prüfen ist auch, ob authentik `text_read_only`-Felder beim Absenden neu auswertet; das Design verlässt sich auf keines der beiden Verhalten. | Erzeugen und Speichern zusammenlegen (§ 5.1) |
| V2 | Validierungs-Policies einer Prompt-Stage laufen beim Absenden, sehen den Plan-Kontext und können mit `False` abweisen | Policy an einer Folge-Stage (Spike-Weg) mit einer Stage ohne sichtbaren Schritt |
| V3 | Ein LDAP-Bind über den Bind-Flow mit dem Backend „authentik Tokens“ funktioniert mit einem App-Passwort-Token eines Servicekontos, und der Token lässt sich ohne Ablauf anlegen | Passwort am Servicekonto setzen |
| V4 | Das Speichern erzeugt keinen Event, der den Hash lesbar enthält | Event-Retention kurz halten und dokumentieren |
| V5 | authentik gibt `wifi-password-nthash` mit Bindestrich unverändert als LDAP-Attribut aus und filtert darauf | Unterstrich-Name in authentik, Mapping nur im Test-Directory |
| V6 | Portainer bindet eine zusätzliche Compose-Datei bei Git-Stacks ein | Compose-Profile (`COMPOSE_PROFILES`) |
| V7 | glauth wertet eigene Attribute und `memberOf` im Suchfilter aus | OpenLDAP mit kleinem Schema |

Geprüft und damit erledigt: `rlm_ldap`, `rlm_mschap`, `rlm_eap_peap` und `rlm_eap_mschapv2`
sind im Basis-Image vorhanden.

## 12. Standardwerte für den Blueprint-Kontext

| Schlüssel | Standard |
|---|---|
| `wlan_group` | `wlan` |
| `ssid` | `WLAN` |
| `radius_server_name` | `radius.example.com` |

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
