# LANE2 - zweite Postfach-Lane (ADR-040)

Stand: Branch `lane2` (forge-ops). Gebaut, **nicht installiert**: keine Unit aktiviert, kein Neustart, `/srv/forge/post` unberuehrt. Ausgangslage: `docs/reports/LANE2_SCOPE.md`.

## 1. Design

**Eine Codebasis, zwei Instanzen.** `bin/forge-postbote.sh` laeuft mit `FORGE_LANE=2` als zweite Lane (Unit `etc/systemd/forge-postbote-lane2.service`); ohne `FORGE_LANE` ist es Lane 1 wie bisher.
Lane-Logik steht in `bin/forge-lanes.sh` (vom Watcher gesourct); der Watcher bekam nur Haken (Pfadvariablen, `lane_route`, `lane_lock_for`/`lane_release`, `lane_close_fds` im Kind).

| | Lane 1 (unveraendert) | Lane 2 |
|---|---|---|
| Eingang | `post/eingang/` | `post/eingang-2/` |
| Lane-flock | `state/.lock` | `state/.lock-lane2` |
| Heartbeat | `state/heartbeat` | `state/heartbeat-lane2` |
| Logstrom | `log/postbote.log` | `log/postbote-lane2.log` |
| Neustart-Flag | `state/restart-requested` | `state/restart-requested-lane2` (`forge-request-restart.sh` waehlt per `FORGE_LANE`) |
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

**Lane 1 bleibt Byte fuer Byte wie heute, solange `eingang-2/` nicht existiert** (kein `locks/`, keine Marker, keine zusaetzlichen Dateien; `tests/compare_watchers.py 77df871` = 30/30 identisch). Existiert `eingang-2/`, "armt" sich Lane 1 *zwischen* zwei Laeufen (`state/lane1-armed` = ihre PID, Log `lane 1 armed`) und nimmt ab dem naechsten Brief dieselben Sperren. Lane 2 startet **nichts**, solange Lane 1 laeuft (flock gehalten, per `/proc/locks` geprueft, kein Probe-Lock) und nicht armed ist (Log `PEER ... waiting`): so kollidiert kein Lane-1-Lauf, der vor der Aktivierung ohne Sperren begann, mit Lane 2; ein noch alter Lane-1-Prozess (Code vor dem Merge) armt sich nie => Lane 2 wartet, bis Lane 1 neu gestartet wurde.

## 2. Tests

`tests/test_lanes.sh` (66 Pruefungen, echte Watcher + Stub-claude, ~4 min): Routing (Pfad, Tag, unbekannter Tag, Tag ohne `eingang-2/`), Lane-flock je Lane, Repo-Sperre (gleich => seriell, verschieden => parallel, `none`, unbekannter Name, mehrere Repos, gleiches K), GO-Sperre (GO+GO seriell, GO+Nicht-GO parallel, GO ohne `repos:`, RUN-Plaene aus JSON, Erwerbsreihenfolge), Heartbeat-/Log-/Neustart-Trennung, Absturz (`kill -9`) je Lane, Aktivierungs-Handshake, begrenztes Warten/SIGTERM/`forge-stop` waehrend des Wartens, STOP fuer beide Lanes, Lane 1 inert. `LANE_TEST_BIN=<bin>` prueft eine andere Revision; `LANE_TEST_SECTIONS="3 6"` einzelne Abschnitte.
`tests/lanes_dryrun_container.sh`: zwei Schein-Auftraege in zwei Lanes in einem Wegwerf-Container (`--rm --network none --read-only`, Repo `:ro`), Zeitleiste + Urteil. Bestehende Suiten (`test_postbote`, `test_heartbeat_env`, `test_restart`, `test_stop`, `test_evidence_order`, `test_run_kind`) unveraendert gruen.

## 3. Installation / Aktivierung (Owner, root) - erst nach Merge von `lane2` nach forge-ops master

Voraussetzung: `lane2` (und `n5prep`) sind in `/srv/forge/work/forge-ops` master gemerged. `lane2` fasst `README.md`, `bin/forge-docker-user.sh` und `tests/test_docker_user_hub.sh` (n5prep) nicht an.

```bash
# A) Pruefen (als forge, ~4 min, nur Wegwerf-Verzeichnisse; nicht im Nachtfenster 01:00-04:45Z)
sudo -u forge bash /srv/forge/work/forge-ops/tests/test_lanes.sh | tail -2          # SUMMARY: 66 passed, 0 failed
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
cat /srv/forge/post/state/lane1-armed /srv/forge/post/state/heartbeat-lane2
tail -n 3 /srv/forge/post/log/postbote-lane2.log                                     # kein PEER-Hinweis mehr = Lane 2 startet Briefe
# E) Rauchtest (Haiku, kostet fast nichts): Brief mit repos: none in den Eingang 2
printf 'repos: none\nAntworte nur PONG.\n' | sudo -u forge tee /srv/forge/post/eingang-2/PING_lane2smoke.exec-claude.aufwand-low.modell-claude-haiku-4-5.md >/dev/null
#    Report in ausgang/ enthaelt '- Lane: 2'
# F) Mac: docs/patches/fp_lane2.patch auf bin/fp.sh anwenden (siehe Kopf der Datei), dann `bash bin/fp.sh send <datei> eingang-2`
```
Lane 2 uebernimmt `claude.env`, `PATH`, `HOME`, `UMask`, `KillMode=mixed` der Lane-1-Unit. Briefe fuer Lane 2 brauchen eine `repos:`-Zeile, sonst sperren sie alle Repos (laufen dann nicht parallel).

## 4. Rollback (Lane 2 aus = Lane 1 wie vorher)

```bash
# 1) Lane 2 leerlaufen lassen (systemctl stop beendet einen laufenden Brief nach TimeoutStopSec=60 hart): Eingang leer, kein claude-Prozess in der Unit
ls /srv/forge/post/eingang-2 ; systemctl status forge-postbote-lane2 | grep -c claude
# 2) abschalten und Unit entfernen (root)
systemctl disable --now forge-postbote-lane2.service
rm /etc/systemd/system/forge-postbote-lane2.service && systemctl daemon-reload
# 3) uebrige Briefe zurueck in Lane 1, Eingang entfernen (als forge) - ab jetzt ist Lane 1 wieder sperrfrei und unveraendert
sudo -u forge sh -c 'mv -n /srv/forge/post/eingang-2/*.md /srv/forge/post/eingang/ 2>/dev/null; rmdir /srv/forge/post/eingang-2'
# 4) optional aufraeumen (als forge): state/locks state/lane1-armed state/.lock-lane2 state/heartbeat-lane2 ; Log log/postbote-lane2.log behalten
sudo -u forge rm -rf /srv/forge/post/state/locks /srv/forge/post/state/lane1-armed /srv/forge/post/state/.lock-lane2 /srv/forge/post/state/heartbeat-lane2
```
Lane 1 wurde nie an der Unit veraendert; ein Code-Rollback ist der Revert des Merge in forge-ops plus `forge-request-restart.sh` (ohne `eingang-2/` ist der neue Code fuer Lane 1 ohnehin inert).

## 5. Kosten

Jede Lane ist **eine zusaetzliche gleichzeitige Claude-Sitzung** auf demselben Plan/Konto (`claude.env` wird geteilt): doppelter Token- und Rate-Limit-Verbrauch im selben Zeitfenster, bei Opus/`aufwand-high` spuerbar; erreicht der Plan sein Limit, scheitern Laeufe beider Lanes (Fehlerreport statt stillem Verlust). Das Planlimit ist auf dem Host nicht einsehbar - Owner-Entscheidung. Warten auf Sperren kostet nichts (keine Sitzung). Hebel: `repos:`-Zeilen (mehr Parallelitaet nur, wo sie sicher ist), ein kuerzeres `FORGE_MAX_SECONDS` fuer Lane 2 per Drop-in (`Environment=FORGE_MAX_SECONDS=7200`), Lane 2 jederzeit per Rollback aus. Zusaetzlich teilen sich beide Lanes CPU/Docker/Postgres des Hosts (zwei schwere Suiten gleichzeitig; Nachtfenster M-47 beachten).

## 6. Offene Punkte

1. **forge-core kennt `eingang-2/` nicht**: Importer (`sync_eingang`), Dispatch und die Container-Mounts sehen nur `eingang/`. Briefe in Lane 2 bekommen bei Annahme keinen Run-Eintrag und keine Importer-Policy-Pruefung (Quarantaene); Belege entstehen erst ueber `erledigt/`/`ausgang/`/`log/` (flach, unveraendert). RUN-Auftraege und `runs_dispatch` bleiben deshalb auf Lane 1 (die Autorisierung in `forge-run-job` gilt unabhaengig). Eigene forge-core-Slice noetig (Mount + Scan + `.lane-N` im Namensschema, `parse_brief_filename`).
2. **`repos:`-Konvention** muss in die Brief-Vorlagen der Planerin; ohne sie gibt es keine Parallelitaet (nur Sicherheit).
3. Sperrdateien `state/locks/k-<K>` wachsen mit der Zahl der Kuerzel (wie `state/<K>.session`); nicht loeschbar ohne Race.
4. Ueberlebt ein Executor den Watcher (kein cgroup-Kill), sind seine Sperren frei - wie beim Lane-flock heute; `KillMode=mixed` + Neustart-Unit beheben das.
5. `fp.sh` liegt nicht auf diesem Host: `docs/patches/fp_lane2.patch` ist gegen eine aus der Doku rekonstruierte Basis geprueft, nicht gegen das Original.
6. README-Verweis auf diese Datei fehlt absichtlich (n5prep fasst `README.md` an); nach dessen Merge eine Zeile ergaenzen.
7. Gleichnamige Briefe in beiden Eingaengen in derselben Sekunde wuerden in `erledigt/`/`ausgang/` kollidieren (Nonce im Namen verhindert das).
