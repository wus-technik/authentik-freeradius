# Leak-Audit: interne Daten im Source-Baum und in der Git-Historie

Datum: 2026-10-28
Umfang: alle getrackten Dateien auf `develop` und die komplette Historie aller Refs
(83 Commits), samt Commit-Messages, Autor-Metadaten und gelöschten Dateien. GitHub-Issues
und PRs gehörten nicht zum Scan.
Methode: manuelles `git grep` / `git log --all -p` mit Mustern für interne Domains und
Hostnamen, RFC-1918-Adressen, UUIDs, Mailadressen, Personennamen, Ticketschlüssel,
Session-URLs, private Schlüssel, Token-Formate und Secret-ähnliche Zuweisungen. Dazu jede
Zertifikats- und Schlüsseldatei, die je in der Historie lag.

## Ergebnis

Im aktuellen Baum stehen keine Site-Daten. Alle Adressen sind Doku- oder Docker-Defaults
(`10.0.0.0/8`, `10.1.0.0/24`, `172.31.253.0/24`, `172.28/29.0.0/16`), alle Domains sind
`example.com`, alle Test-Secrets tragen den Zusatz `not-a-real-one`.

## Befunde

| # | Schwere | Fundstelle | Befund | Urteil |
|---|---------|------------|--------|--------|
| 1 | niedrig | Commit `c1183c7`, Betreffzeile | Der Betreff nennt den internen Hostnamen des abgelösten Servers. Adresse und Domain fehlen. | Akzeptiert. Ändern ginge nur per History-Rewrite. |
| 2 | niedrig | Commit-Trailer (rund 40 Commits) | `Claude-Session:`-URLs. Aufrufbar sind sie nur mit einem Login beim Konto, dem die Session gehört. | Akzeptiert. Die Trailer sind gewollt. |
| 3 | niedrig | Blobs vor `f7132e9` (`a1902b0`, `8f72495`, `757989d`, `2b322cb`) | Vorname eines Maintainers in Spec- und Plantext, dazu eine Session-URL in einem Plan. Mit `f7132e9` aus dem Baum entfernt. | Akzeptiert. Der Name steht ohnehin in den Autor-Metadaten. |
| 4 | Info | Commits `207dd13`, `9bbfc8f`, `3239ff0` (Upstream, 2022–2023) | Private Schlüssel und Zertifikate (`server.key`, `pc.key`, `pc.p12`, `certs/*`) aus dem geforkten Upstream-Projekt, ausgestellt von dessen Lab-CA `CN=AWASLab`. Die Leaf-Zertifikate sind seit 2023 abgelaufen. | Nicht unsere Daten, nichts zu rotieren. Unverändert gelassen. |
| 5 | Info | `contrib/zabbix/template_authentik_freeradius.yaml:24,484` | Als Vendor des Templates steht der Name der Organisation. | Gewollt. Das Repo liegt unter dieser Organisation. |

Weder im Baum noch in der Historie fanden sich Credentials, Tokens, echte Secrets, interne
IP-Adressen, AD-Domains, AP-Namen oder Outpost-UUIDs.

## Außerhalb des Umfangs

In den Issues #4 und #7 stehen bekanntermaßen noch echte Subnetze und Hostnamen aus der
Zeit vor der Public-Repo-Regel. Das braucht eine eigene Entscheidung: Issue-Texte
bereinigen und die Edit-Historie der Issues prüfen.
