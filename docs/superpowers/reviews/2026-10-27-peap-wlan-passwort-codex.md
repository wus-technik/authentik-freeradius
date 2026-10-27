# Codex-Review: PEAP-MSCHAPv2 mit generiertem WLAN-Passwort

- **Datum:** 2026-10-27
- **Umfang:** `031177c..HEAD` auf `develop` (Spec bis `7477bf7`), geprüft gegen
  `docs/superpowers/specs/2026-10-13-peap-wlan-passwort-design.md` und den Plan.
- **Modell:** Codex CLI 0.163.0, `gpt-6.1-sol`, Reasoning `high`, Sandbox read-only:
  `codex exec --sandbox read-only --model gpt-6.1-sol -c model_reasoning_effort=high -`
- **Urteil:** CHANGES_REQUESTED
- **Gelaufen:** die Python-Unit-Tests (grün). Die e2e- und Integrationstests nicht, weil die
  Sandbox keinen Docker-Zugriff hatte.

## Befunde

| # | Schwere | Ort | Befund | Status |
|---|---------|-----|--------|--------|
| 1 | hoch | `authentik/src/wlan-passwort.yaml.in` (Flow `wlan-ldap-bind`) | Ohne `authentication: require_outpost` kann ein Browser den Bind-Flow ausführen und bekommt mit Benutzername und Passwort eine SSO-Session, ohne MFA. | behoben |
| 2 | mittel | `wifi_password_generate.expr`, `wifi_password_save.expr` | Veralteter Tab: A und B zeigen P, B speichert P und lädt neu, dabei entsteht Q. Schickt A seine alte Seite ab, wird Q gespeichert, obwohl A weiter P anzeigt. | akzeptiert, dokumentiert |
| 3 | mittel | `wifi_password_save.expr` | `pending["base"]` wird in der Transaktion nicht mit `wifi-password-set-at` verglichen; zwei Sessions können nacheinander speichern, die zweite überschreibt still. | behoben |
| 4 | mittel | `wifi_password_save.expr`, `docs/authentik.md` | Das Klartext-Passwort könnte über den Flow-Plan in der Session-History bis zum Session-Ende in PostgreSQL liegen. | bestätigt, behoben |
| 5 | mittel | Spec §1, `docs/rollout-mail.de.md` | „Sofort wirksam“ gilt nicht für schon verbundene Geräte (kein CoA/Disconnect-Request), sondern ab der nächsten Anmeldung. | behoben (Doku) |
| 6 | mittel | `test/authentik/drive.py`, `run.sh` | Spec §8.3 verlangt die §8.1-Fälle gegen den echten Outpost; es fehlen: Hash ohne Gruppe, aus der Gruppe entfernt, Gruppenmitglied ohne Hash. | behoben |
| 7 | niedrig | `test/authentik/run.sh` (`rejected`) | Die Prüfung „falsches Passwort“ erkennt nur, dass der `notfound`-Zähler gleich bleibt; ein LDAP-Fehler sähe genauso aus. | behoben |
| 8 | niedrig | Plan, Specs | Personennamen und Session-URLs im öffentlichen Repo. | behoben (Arbeitskopie; die Git-Historie enthält sie weiter) |

Ohne Befund blieben das Escaping der Secrets im Entrypoint, der LDAP-Filter, das Netz- und
Adressschema in Compose und `md4.py`.

## Umsetzung

- **1:** `authentication: require_outpost` am Flow `wlan-ldap-bind`, Blueprint neu erzeugt.
  Der Integrationstest prüft mit `drive.py nobrowserbind`, dass ein Browser `ak-stage-access-denied`
  bekommt. PEAP über den Outpost funktioniert weiter (Integrationstest grün).
- **3:** Die Speicher-Policy lehnt in der Transaktion ab, wenn sich `wifi-password-set-at` seit dem
  Erzeugen der Passphrase geändert hat. Zwei Unit-Tests decken Ablehnung und Normalfall ab.
- **8:** Namen durch „Maintainer“ ersetzt, Session-Trailer aus den Commit-Beispielen im Plan entfernt.
- **4:** Bestätigt mit einem Integrationstest (`test/authentik/session_check.py`), der die
  gespeicherten Sessions in der Datenbank nach dem Klartext durchsucht: Er lag unter
  `authentik/flows/history`. Der Executor legt nach jeder Stage eine Kopie des Plans samt
  `prompt_data` dort ab und löscht die History am Flow-Ende bewusst nicht. Die Speicher-Policy
  entfernt `wifi_password` jetzt nach dem Speichern aus `prompt_data`; die Policy läuft im selben
  Prozess, also landet der Wert weder im Plan noch in der History. Test danach grün.
- **5:** Spec, `docs/authentik.md` und Rundmail sagen jetzt „ab der nächsten Anmeldung“; schon
  verbundene Geräte bleiben verbunden, es gibt keinen Disconnect-Request.
- **6:** Integrationstest: Nutzer mit Hash ohne Gruppe, nach Hinzufügen angenommen (Gegenprobe,
  dass der Hash gilt), nach Entfernen abgelehnt, Gruppenmitglied ohne Hash abgelehnt.
- **7:** Ein Hinweis von MSCHAPv2 ist am Client nicht zu sehen: FreeRADIUS schickt kein `E=691`,
  der Client sieht bei falschem Passwort und bei LDAP-Fehler dasselbe. Deshalb loggt FreeRADIUS
  jetzt `peap: wrong WiFi password: <user>` (`Auth-Type mschap` mit `peap_log_badpass`). Der
  Testhelfer verlangt für jeden Ablehnungsgrund genau seine Logzeile und dass die andere nicht
  dazukommt. Die e2e-Suite prüft die neue Zeile, Monitoring- und Troubleshooting-Doku nennen sie.

## Zu Befund 2

In authentik 2026.8.3 lässt sich die Seite, die abgeschickt wurde, in der Validierungs-Policy nicht
erkennen. `PromptChallengeResponse.validate` überschreibt die Werte aller Felder der Typen
`hidden`, `static`, `text_read_only` und `text_area_read_only` mit dem serverseitigen Initialwert.
Die Policy bekommt den Django-`HttpRequest`, dessen Body DRF schon gelesen hat. Eine versteckte
Kennung pro Seite kommt also nie beim Server an. Eine Lösung braucht ein Feld, das der Browser
wirklich überträgt, etwa die Bestätigung durch Eintippen eines Worts der Passphrase statt der
Checkbox.

**Entscheidung (Maintainer, 2026-10-27):** keine UX-Änderung. Der Fall braucht zwei Tabs und
endet harmlos: Das gemerkte Passwort funktioniert nicht, und man holt sich im Portal ein neues.
Er steht als bekannte Lücke in `docs/authentik.md`. Dazu sagt die Seite jetzt, dass das Passwort
gleich im Passwort-Manager zu speichern ist (Kontext `password_manager`, Standard `Bitwarden`).
