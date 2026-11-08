# LANE2 - zweite Postfach-Lane (ADR-040)

Stand: Branch `lane2` (forge-ops). Gebaut, **nicht installiert**: keine Unit aktiviert, kein Neustart, `/srv/forge/post` unberuehrt. Ausgangslage: `docs/reports/LANE2_SCOPE.md`.

## 1. Design

**Eine Codebasis, zwei Instanzen.** `bin/forge-postbote.sh` laeuft mit dem Argument `--lane 2` als zweite Lane (Unit `etc/systemd/forge-postbote-lane2.service`, `ExecStart=... --lane 2`); ohne `--lane` ist es Lane 1 wie bisher. Die Lane kommt **nur aus dem Argument**: eine Umgebungsvariable `FORGE_LANE` hat keine Wirkung (der Watcher `unset`et sie) und steht in keiner Executor-Umgebung (Verify m-2).
Lane-Logik steht in `bin/forge-lanes.sh` (vom Watcher gesourct); der Watcher bekam nur Haken (Pfadvariablen, `lane_route`, `lane_lock_for`/`lane_release`, `lane_close_fds` im Kind).

| | Lane 1 (unveraendert) | Lane 2 |
|---|---|---|
| Eingang | `post/eingang/` | `post/eingang-2/` |
| Lane-flock | `state/.lock` | `state/.lock-lane2` |
| Heartbeat | `state/heartbeat` | `state/heartbeat-lane2` |
| Logstrom | `log/postbote.log` | `log/postbote-lane2.log` |
| Neustart-Flag | `state/restart-requested` | `state/restart-requested-lane2`; `forge-request-restart.sh` schreibt bei vorhandenem `eingang-2/` **immer beide Flags** - ein Neustart-Wunsch (auch aus einem Lane-2-GO) gilt fuer BEIDE Watcher, jeder wirkt zwischen seinen Runs |
| Report-Tag | (keine Zeile, wie heute) | `- Lane: 2` im Report-Kopf |
| gemeinsam | `erledigt/`, `ausgang/`, Roh-Logs `log/<ts>_<base>.json|.stderr` (flach, der Importer globbt flach), `state/<K>.session|exec`, `control/STOP`, `control/.dispatch.lock` | |

**Eingang als Geschwisterverzeichnis `eingang-2/`, nicht `eingang/lane2/`**, weil (a) forge-core `eingang/` rw in mehrere Container mountet (`compose.yaml:55,89,248,362`) und `sync_eingang` es flach globbt - ein Unterverzeichnis dort waere ein fremdes Objekt in einem Verzeichnis, das Importer/Dispatch als ihr eigenes ansehen; (b) `mkenv.sh` leitet UID/GID aus `eingang/` ab; (c) `next_brief` (`find -maxdepth 1`) und Rechte (2775 forge:forgebox) bleiben je Lane trivial; (d) das Verzeichnis ist zugleich das Aktivierungssignal fuer Lane 1 (s. u.).

**Routing.** Der Eingang entscheidet. Optional traegt der Dateiname `.lane-<N>` (direkt vor `.n-<8 hex>` bzw. `.md`, N = 1|2): liegt ein Brief mit fremdem Tag im Eingang, verschiebt ihn der Watcher atomar (`mv -n`) in den Ziel-Eingang (Log `ROUTED`), aber nur wenn dieser existiert; sonst bleibt alles wie heute (Schemafehler => ABGELEHNT). Das eigene Tag wird fuer die Schema-Pruefung abgezogen, der Report nennt den vollen Namen.

**Sperren** (`flock`, Dateien `state/locks/*`, alle vom Watcher-Prozess gehalten, im Kind/Heartbeat geschlossen => bei Absturz frei, wie der Lane-flock):
1. `all` - **S** (geteilt) fuer jeden Lauf; **X** fuer Laeufe mit unbekanntem Repo-Satz (sperrt alles)
2. `deploy` - **X** fuer jeden `GO_*`-Brief und die RUN-Jobs `merge`/`deploy-stage` (nie zwei GOs/Deploys gleichzeitig, lane-uebergreifend)
3. `repo-<name>` - **X** je Repo des Laufs, alphabetisch
4. `k-<K>` - **X** je Kuerzel (schuetzt `state/<K>.session|exec`)

Feste Erwerbsreihenfolge => kein Deadlock. **Repo-Satz:** Zeile `repos: forge-core, forge-ops` (auch `Repos:`, `**Repos:**`, `> repos:`) in den ersten 30 Zeilen des Briefs; `repos: none` = kein Repo; `repos: all`, fehlende Zeile, ungueltiger Name oder Name nicht in `etc/lane-repos.list` => **ALLE** (sicherer Standard). RUN: `args.repo` aus dem JSON (unlesbar => ALLE + deploy).
**Warten** ist begrenzt (`FORGE_LANE_LOCK_WAIT`, Standard 18000 s > `FORGE_MAX_SECONDS` 14400), geloggt (`LOCKWAIT ... waiting / still waiting / acquired after / TIMEOUT / aborted`, mit Halter), haelt den Heartbeat am Leben, bricht bei SIGTERM ab. Nach Ablauf bleibt der Brief in `eingang*/` und wird erneut versucht - nie stilles Scheitern. Die Sperren werden **vor** dem Dispatch-Lock genommen: Warten haelt `control/.dispatch.lock` nie, `forge-stop` geht jederzeit. `STOP` gilt fuer beide Lanes.

**Lane 1 bleibt Byte fuer Byte wie master, solange `eingang-2/` nicht existiert** (kein `locks/`, keine Marker, keine zusaetzlichen Dateien, auch Lane-Tags im Namen: `.lane-N` wird wie auf master behandelt, also ABGELEHNT bzw. Teil der Modell-ID; `tests/compare_watchers.py 476d335` = 55/55 identisch inkl. getaggter Namen). Existiert `eingang-2/`, "armt" sich Lane 1 *zwischen* zwei Laeufen: `state/lane1-armed` = `<PID> <Startzeit>` ihres Watchers (Log `lane 1 armed`), und sie nimmt ab dem naechsten Brief dieselben Sperren. Lane 2 startet **nichts**, solange Lane 1 laeuft (flock gehalten, per `/proc/locks` geprueft, kein Probe-Lock) und nicht armed ist - PID **und** Startzeit muessen zu einem lebenden Prozess passen (Log `PEER ... waiting`). Ein noch alter Lane-1-Prozess (Code vor dem Merge) armt sich nie => Lane 2 wartet, bis Lane 1 neu gestartet wurde.
**Veraltete Zustandsdateien (Verify M-1).** Der Marker gilt nur, solange *kein sperrfreier Lane-1-Lauf* laeuft. Darum loescht Lane 1 ihn selbst, sobald `eingang-2/` fehlt - im Schleifenkopf und zusaetzlich unmittelbar vor jedem sperrfreien Lauf (erst loeschen, dann `eingang-2/` erneut pruefen; entsteht das Verzeichnis genau jetzt, sperrt Lane 1 doch). Ein Rollback ohne Aufraeumen und eine Re-Aktivierung mitten im sperrfreien Lauf lassen Lane 2 deshalb warten (Test Abschnitt 10). Audit aller Dateien, denen die Lane-Logik traut:

| Datei | Vertraut als | Veralten moeglich? | Absicherung |
|---|---|---|---|
| `state/lane1-armed` | "Lane 1 sperrt" | ja (Rollback, PID-Wiederverwendung) | Lane 1 loescht ihn bei fehlendem `eingang-2/`; PID+Startzeit; Rollback loescht ihn zusaetzlich (Pflicht) |
| `state/.lock`, `.lock-lane2`, `locks/*` | flock (Kernel) | nein - der Kernel gibt bei Prozessende frei | **nie loeschen/ersetzen** (Prozess haelt Sperre auf dem alten Inode): kein `rm` im Rollback |
| `state/locks/holders/*` | nur Auskunft im Log | ja | wird nie fuer Entscheidungen gelesen |
| `/proc/locks` (`lane1_running`) | "Lane 1 laeuft" | nein (Kernel); Inode-Treffer anderer Dateisysteme nur im sicheren Sinn | nicht lesbar => "laeuft" |
| `eingang-2/` | Aktivierungssignal | ja (Verzeichnis bleibt stehen) | sicherer Fall: Lane 1 sperrt weiter |
| `restart-requested-lane2` | Neustart-Wunsch | ja | loescht sich beim naechsten Start von Lane 2; Rollback loescht ihn |
| `control/STOP` | globale Pause | gewollt | `forge-release` |

## 2. Tests

`tests/test_lanes.sh` (@@N@@ Pruefungen, echte Watcher + Stub-claude, ~4 min): Routing (Pfad, Tag, unbekannter Tag, Tag ohne `eingang-2/` inkl. `.lane-1`), Lane-flock je Lane, Repo-Sperre (gleich => seriell, verschieden => parallel, `none`, unbekannter Name, mehrere Repos, gleiches K), GO-Sperre (GO+GO seriell, GO+Nicht-GO parallel, GO ohne `repos:`, RUN-Plaene aus JSON, Erwerbsreihenfolge), Heartbeat-/Log-/Neustart-Trennung (beide Flags), Absturz (`kill -9`) je Lane, Aktivierungs-Handshake, **Re-Aktivierung nach Rollback mit veraltetem Marker (Abschnitt 10; auf cbb68ab: Overlap)**, **keine Lane-Variable in Executor-Umgebungen / Neustart aus einem Lane-2-GO (Abschnitt 11)**, begrenztes Warten/SIGTERM/`forge-stop` waehrend des Wartens, STOP fuer beide Lanes, Lane 1 inert. `tests/mutation_lanes.sh`: 20 gezielte Defekte (kein Repo-/Deploy-/K-Lock, gemeinsamer Heartbeat/Log/flock, Sperren im Kind offen, kein Peer-Handshake, kein Timeout/SIGTERM-Abbruch, Routing aus, Lane 1 sperrt immer, Marker nie geloescht, Marker ohne Startzeit, `.lane-1` ohne `eingang-2/` akzeptiert, Lane-Variable im Executor, Neustart nur fuer eine Lane) - alle erkannt. Gegen master (`LANE_TEST_BIN=<git archive 476d335 bin>`): @@MASTER@@ `LANE_TEST_BIN=<bin>` prueft eine andere Revision; `LANE_TEST_SECTIONS="3 6"` einzelne Abschnitte; `LANE_TEST_KEEP=1` behaelt das Wegwerf-Verzeichnis.
`tests/lanes_dryrun_container.sh`: zwei Schein-Auftraege in zwei Lanes in einem Wegwerf-Container (`--rm --network none --read-only`, Repo `:ro`), Zeitleiste + Urteil. Bestehende Suiten (`test_postbote`, `test_heartbeat_env`, `test_restart`, `test_stop`, `test_evidence_order`, `test_run_kind`, `test_write_result`, `test_ci_gates_table`) sind unveraendert gruen - mit ungesetztem UND mit gesetztem `FORGE_LANE=2` in der Eltern-Umgebung (z. B. ein forge-ops-Verify in einem Lane-2-Executor).

## 3. Installation / Aktivierung (Owner, root) - erst nach Merge von `lane2` nach forge-ops master

### Aktivierungs-Checkliste (Merge-GO-Invarianten aus dem Verify, alle muessen gelten)

1. Der Merge-Kopf von `lane2` laesst sich konfliktfrei auf forge-ops master (476d335 bzw. aktuelle Spitze) mergen; gemergt wird nur im Produktions-Checkout, **ohne dort Branches zu wechseln** (der laufende Watcher liest sein Skript von dort).
2. `compare_watchers.py 476d335` identisch (55/55), `test_lanes.sh` gruen, `mutation_lanes.sh` alle erkannt, alle bestehenden Suiten gruen (mit und ohne `FORGE_LANE=2` in der Umgebung).
3. `/srv/forge/post/eingang-2` existiert beim Merge **nicht** (Lane 1 bleibt sperrfrei).
4. Lane 1 wird mit `forge-request-restart.sh` neu gestartet; `RESTART` im Log und ein neuer `ExecMainStartTimestamp` sind bestaetigt, **bevor** `eingang-2` angelegt wird.
5. `state/lane1-armed` traegt die aktuelle `MainPID` von Lane 1, **bevor** die Lane-2-Unit aktiviert wird; der Rauchtest-Report enthaelt `- Lane: 2`.
6. **Keine Kundendaten-Briefs und keine RUN-Auftraege in Lane 2 und keine `.lane-N`-Namen in `eingang/`**, bis die forge-core-Slice steht (der Importer scannt `eingang-2/` nicht: keine Sensitivitaets-Quarantaene, kein Run-Eintrag; `.lane-N` in `eingang/` wuerde er als Lane-1-Run registrieren). RUN-Jobs sind unabhaengig davon durch `forge-run-job` (consume_order) abgesichert, gehoeren aber auf Lane 1.
7. **GO-Briefs nennen kein enges `repos:`** (Standard "alle Repos"): Produktionsressourcen (Postgres, Container, Units) sind nicht je Repo getrennt; ein GO sperrt deshalb alles.
8. Rollback-Reihenfolge exakt wie in Abschnitt 4 (Marker loeschen ist Pflicht); Code-Revert erst danach.
9. Nach **jedem** forge-ops-Merge werden BEIDE Lanes neu gestartet (ein Neustart-Wunsch per `forge-request-restart.sh` erreicht beide, solange `eingang-2/` existiert) - sonst laeuft die andere Lane mit altem Code weiter. Ein Merge, der die Deploy-Menge der RUN-Jobs aendert (`bin/jobs/*`, S5b: `lock-set`/`acceptance`/`deploy-check` werden real), prueft `lane_plan` (`merge`, `deploy-stage`).

Voraussetzung: `lane2` (und `n5prep`) sind in `/srv/forge/work/forge-ops` master gemerged. `lane2` fasst `bin/forge-docker-user.sh` und `tests/test_docker_user_hub.sh` (n5prep) nicht an; in der README ergaenzt sie nur einen kurzen Abschnitt.

```bash
# A) Pruefen (als forge, ~3 min, nur Wegwerf-Verzeichnisse; nicht im Nachtfenster 01:00-04:45Z)
sudo -u forge bash /srv/forge/work/forge-ops/tests/test_lanes.sh | tail -2          # SUMMARY: 67 passed, 0 failed
# B) Lane 1 auf den neuen Code bringen (Neustart NACH dem aktuellen Run; Lane 1 aendert sich ohne eingang-2/ nicht)
sudo -u forge /srv/forge/work/forge-ops/bin/forge-request-restart.sh "lane2 code"
#    warten, bis der Neustart im Log steht:
grep RESTART /srv/forge/post/log/postbote.log | tail -1 ; systemctl show forge-postbote -p ExecMainStartTimestamp
# C) Eingang anlegen, Unit installieren, starten (root)
install -d -o forge -g forgebox -m 2775 /srv/forge/post/eingang-2
install -m 0644 /srv/forge/work/forge-ops/etc/systemd/forge-postbote-lane2.service /etc/systemd/system/forge-postbote-lane2.service
systemctl daemon-reload
systemctl enable --now forge-postbote-lane2.service
# D) Pruefen
systemctl is-active forge-postbote forge-postbote-lane2                              # active active
tail -n 3 /srv/forge/post/log/postbote.log                                           # ... lane 1 armed (nach dem laufenden Run)
cat /srv/forge/post/state/lane1-armed /srv/forge/post/state/heartbeat-lane2          # lane1-armed = "<MainPID von forge-postbote> <Startzeit>"
test "$(cut -d' ' -f1 /srv/forge/post/state/lane1-armed)" = "$(systemctl show forge-postbote -p MainPID --value)" && echo armed-ok
tail -n 3 /srv/forge/post/log/postbote-lane2.log                                     # kein PEER-Hinweis mehr = Lane 2 startet Briefe
# E) Rauchtest (Haiku, kostet fast nichts): Brief mit repos: none in den Eingang 2
printf 'repos: none\nAntworte nur PONG.\n' | sudo -u forge tee /srv/forge/post/eingang-2/PING_lane2smoke.exec-claude.aufwand-low.modell-claude-haiku-4-5.md >/dev/null
#    Report in ausgang/ enthaelt '- Lane: 2'
# F) Mac: docs/patches/fp_lane2.patch auf bin/fp.sh anwenden (siehe Kopf der Datei), dann `bash bin/fp.sh send <datei> eingang-2`
```
Lane 2 uebernimmt `claude.env`, `PATH`, `HOME`, `UMask`, `KillMode=mixed` der Lane-1-Unit. Briefe fuer Lane 2 brauchen eine `repos:`-Zeile, sonst sperren sie alle Repos (laufen dann nicht parallel).

## 4. Rollback (Lane 2 aus = Lane 1 wie vorher) - Reihenfolge ist Pflicht

```bash
# 1) Neue Briefe anhalten (beide Lanes; laufende Briefe laufen weiter) - als forge
sudo -u forge /srv/forge/work/forge-ops/bin/forge-stop "lane2 rollback"
# 2) Warten, bis Lane 2 leer laeuft (sonst beendet systemctl stop einen laufenden Brief nach TimeoutStopSec=60 hart): kein claude-Prozess in der Unit
systemctl status forge-postbote-lane2 | grep -c claude          # 0 abwarten; letzte Zeile in log/postbote-lane2.log ist eine Report-Zeile
# 3) Lane 2 abschalten und Unit entfernen (root)
systemctl disable --now forge-postbote-lane2.service
rm /etc/systemd/system/forge-postbote-lane2.service && systemctl daemon-reload
# 4) uebrige Briefe zurueck in Lane 1 - `.lane-2` aus dem Namen entfernen (sonst ABGELEHNT) - und Eingang entfernen (als forge)
sudo -u forge sh -c 'for f in /srv/forge/post/eingang-2/*.md; do [ -e "$f" ] || continue; n=$(basename "$f"); mv -n "$f" "/srv/forge/post/eingang/${n/.lane-2/}"; done; rmdir /srv/forge/post/eingang-2'
# 5) PFLICHT: veraltete Zustandsdateien loeschen (Lane 1 loescht lane1-armed zwar selbst, sobald eingang-2/ fehlt - das hier ist der Gurt zum Hosenträger)
sudo -u forge rm -f /srv/forge/post/state/lane1-armed /srv/forge/post/state/restart-requested-lane2
#    NICHT loeschen: state/locks/, state/.lock, state/.lock-lane2 (ein laufender Lane-1-Lauf haelt Sperren auf dem alten Inode; neue Dateien wuerden den gegenseitigen Ausschluss aufheben)
# 6) Freigeben
sudo -u forge /srv/forge/work/forge-ops/bin/forge-release
```
Optional: `heartbeat-lane2` entfernen, `log/postbote-lane2.log` archivieren. Code-Rollback (Revert des Merge in forge-ops plus `forge-request-restart.sh`) **erst nach** Schritt 6: alter Code kennt `--lane` nicht und liefe mit der Lane-2-Unit als zweite Lane 1.

## 5. Kosten

Jede Lane ist **eine zusaetzliche gleichzeitige Claude-Sitzung** auf demselben Plan/Konto (`claude.env` wird geteilt): doppelter Token- und Rate-Limit-Verbrauch im selben Zeitfenster, bei Opus/`aufwand-high` spuerbar; erreicht der Plan sein Limit, scheitern Laeufe beider Lanes (Fehlerreport statt stillem Verlust). Das Planlimit ist auf dem Host nicht einsehbar - Owner-Entscheidung. Warten auf Sperren kostet nichts (keine Sitzung). Hebel: `repos:`-Zeilen (mehr Parallelitaet nur, wo sie sicher ist), ein kuerzeres `FORGE_MAX_SECONDS` fuer Lane 2 per Drop-in (`Environment=FORGE_MAX_SECONDS=7200`), Lane 2 jederzeit per Rollback aus. Zusaetzlich teilen sich beide Lanes CPU/Docker/Postgres des Hosts (zwei schwere Suiten gleichzeitig; Nachtfenster M-47 beachten).

## 6. Offene Punkte

1. **forge-core kennt `eingang-2/` nicht**: Importer (`sync_eingang`), Dispatch und die Container-Mounts sehen nur `eingang/`. Briefe in Lane 2 bekommen bei Annahme keinen Run-Eintrag und keine Importer-Policy-Pruefung (Quarantaene); Belege entstehen erst ueber `erledigt/`/`ausgang/`/`log/` (flach, unveraendert). RUN-Auftraege und `runs_dispatch` bleiben deshalb auf Lane 1 (die Autorisierung in `forge-run-job` gilt unabhaengig). Eigene forge-core-Slice noetig (Mount + Scan + `.lane-N` im Namensschema, `parse_brief_filename`).
2. **Deploy-Menge** der RUN-Jobs (`merge`, `deploy-stage`) ist fest in `lane_plan`; `lock-set`, `acceptance`, `deploy-check` sind heute Stubs (Verify m-3) und beim Realwerden in S5b neu zu bewerten.
3. **`repos:`-Konvention** muss in die Brief-Vorlagen der Planerin; ohne sie gibt es keine Parallelitaet (nur Sicherheit).
4. Sperrdateien `state/locks/k-<K>` wachsen mit der Zahl der Kuerzel (wie `state/<K>.session`); nicht loeschbar ohne Race.
5. Ueberlebt ein Executor den Watcher (kein cgroup-Kill), sind seine Sperren frei - wie beim Lane-flock heute; `KillMode=mixed` + Neustart-Unit beheben das.
6. `fp.sh` liegt nicht auf diesem Host: `docs/patches/fp_lane2.patch` ist gegen eine aus der Doku rekonstruierte Basis geprueft, nicht gegen das Original.
7. README: ein Abschnitt "Zweite Postfach-Lane" verweist auf diese Datei (n5prep ist inzwischen in master; der Abschnitt steht oben in der README, n5prep haengte unten an: kein Konflikt).
8. Gleichnamige Briefe in beiden Eingaengen in derselben Sekunde wuerden in `erledigt/`/`ausgang/` kollidieren (Nonce im Namen verhindert das).
