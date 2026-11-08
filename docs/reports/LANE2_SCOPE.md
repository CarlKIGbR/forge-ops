# LANE2_SCOPE - heutiges Ein-Lane-Design des Postboten (Stand forge-ops master 77df871)

Zweck: Ausgangslage fuer die zweite Postfach-Lane (Owner-Entscheidung ADR-040: zweiter Watcher mit eigenem Eingang und eigenem flock). Nur Bestandsaufnahme, keine Aenderung.
Alle Zeilenangaben beziehen sich auf `bin/forge-postbote.sh` @77df871, sofern nicht anders genannt.

## 1. Bestandteile

| Was | Wo | Beleg |
|---|---|---|
| Watcher | `forge-ops/bin/forge-postbote.sh` (406 Zeilen), laeuft aus dem Checkout `/srv/forge/work/forge-ops` (master) | Drop-in `ExecStart=/srv/forge/work/forge-ops/bin/forge-postbote.sh` |
| systemd-Unit | `/etc/systemd/system/forge-postbote.service` (Type=simple, User=forge, Group=forgebox, UMask=0002, `Restart=always`, `RestartSec=5`, `NoNewPrivileges=yes`, `TimeoutStopSec=60`, `WorkingDirectory=/srv/forge/work`, `EnvironmentFile=/srv/forge/secrets/claude.env`) | `systemctl cat forge-postbote` |
| Drop-ins | `10-forge-ops.conf` (ExecStart auf das Repo, angelegt von `owner/F2_switch_watcher.sh`), `20-killmode.conf` (`KillMode=mixed`) | `/etc/systemd/system/forge-postbote.service.d/` |
| Konfiguration | NUR Umgebung (keine Config-Datei): `FORGE_BASE` (Unit: `/srv/forge`), `FORGE_MAX_SECONDS`, `FORGE_RUN_MAX_SECONDS`, `FORGE_POLL`, `FORGE_MIN_AGE`, `FORGE_PERMISSION_MODE`, `FORGE_STOP_FILE`, `FORGE_DISPATCH_LOCK`, `FORGE_LOCK_TIMEOUT`, `FORGE_HB_INTERVAL`, `CLAUDE_BIN`, `CODEX_BIN` | Kopfkommentar :18-:20, Code :33-:39, :51-:52, :145 |
| Neustart / Stop | `bin/forge-request-restart.sh` (Flag `state/restart-requested`), `bin/forge-stop` / `bin/forge-release` (`control/STOP`, `control/.dispatch.lock`) | `forge-request-restart.sh:11-20`, `forge-stop:8-14` |

## 2. Verzeichnis- und Dateilayout (`$BASE` = /srv/forge, `$POST` = $BASE/post)

| Pfad | Rolle | Beleg |
|---|---|---|
| `post/eingang/` | EINZIGER Eingang; Auswahl `find -maxdepth 1 -type f -name '*.md' ! -name '.*'`, aeltester (mtime) zuerst, Mindestalter `FORGE_MIN_AGE` (3 s) | `:53`, `next_brief :154-165` |
| `post/ausgang/REPORT_<base>_<ts>.md` | Reports, atomar `.teil` -> `mv` | `write_report :132-135`, `reportname :197` |
| `post/erledigt/<ts>_<name>` | Archiv; Archivierung VOR dem Report (Run-ID = Archivname) | `:232`, `:362-363` |
| `post/log/postbote.log` | EIN Logstrom (Zeile je Run, `REJECTED`, `RESTART requested`, `paused by STOP`, `resumed`, `control unavailable`) | `:234`, `:364`, `:375`, `:380`, `:385`, `:391-392` |
| `post/log/<ts>_<base>.json` / `.stderr` | Roh-Ausgabe je Run (flach in `log/`; der forge-core-Importer globbt flach nach `*_<base>.json`, `evidence.py` `_scan(s.logdir...)`) | `:241` |
| `post/state/.lock` | Lane-flock, FD 9, `flock -n` (zweite Instanz: "Postbote laeuft bereits", Exit 1) | `:58-62` |
| `post/state/heartbeat` | UTC-Zeitstempel; Schleifenkopf (`:369`) + waehrend eines Runs alle `FORGE_HB_INTERVAL` (45 s) durch einen Hintergrund-Subshell | `heartbeat :137-139`, `hb_start/hb_stop :142-151` |
| `post/state/<K>.session`, `<K>.exec` | Session-/Executor-Kennung je Kuerzel K (fuer `.fortsetzung`) | `:246-253`, `:331-334` |
| `post/state/restart-requested` | Neustart-Flag, wirkt nur zwischen Runs; Watcher beendet sich mit 0, systemd startet neu | `:50`, `:372-377` |
| `post/control/STOP`, `control/.dispatch.lock` | Kill-Switch + Dispatch-Lock (FD 8): "letzte STOP-Pruefung -> Executor spawnen" laeuft unter dem Lock, danach frei | `claim_lock :169-181`, `unclaim :182-185` |
| `post/quarantaene/`, `post/graph/`, `post/live/`, `post/anhang/` | nicht vom Watcher beschrieben (Importer / Graph / State-Snapshot / Anhaenge) | - |

Konsumenten ausserhalb des Watchers: forge-core-Importer und forge-mcp haengen `post/eingang` (rw), `log`, `erledigt`, `ausgang`, `state`, `quarantaene` ein (`forge-core/compose.yaml:55,89,248,362`); `sync_eingang` (`importer.py:310`) globbt `eingang/*.md` flach; `mkenv.sh:16-17` liest UID/GID von `eingang/`. Mac-Seite `bin/fp.sh` (`send <datei> eingang`, `pull`, `status`) liegt ausserhalb dieses Repos (Planerin: Linux-VM per device_bash).

## 3. Ablauf eines Briefs (strikt sequentiell)

1. Schleife (:368-405): Heartbeat -> Neustart-Flag -> STOP-Pruefung -> `next_brief` -> `process` -> sofort naechster, sonst `sleep $POLL`.
2. `process` (:187-366): `claim_lock` (Dispatch-Lock + STOP) -> Dateiname gegen Schema `re` (:196; ART BRIEF|WEISUNG|NACHFORDERUNG|GO|PING|RUN) -> bei Verstoss Report "ABGELEHNT" (:220-238) -> Argumente fuer `claude -p` bzw. `codex exec` (:259-278) oder RUN: `bin/forge-run-job` mit leerem Environment (:287-291).
3. Executor wird in einem Subshell gestartet; `9>&- 8>&-` schliesst Lane-Lock und Dispatch-Lock im Kind (:291, :293), `unclaim` direkt nach dem Spawn (:296), dann Heartbeat-Hintergrund (:297), `wait` (:298-300).
4. Zeitlimit: `timeout ${FORGE_MAX_SECONDS:-14400}` (Executor, :293), `timeout ${FORGE_RUN_MAX_SECONDS:-3900}` (RUN, :291); rc 124 -> Hinweis im Report (:337-339).
5. Ergebnis -> Report-Kopf (:341-360) -> Archiv (:362) -> Report (:363) -> Logzeile (:364).
6. Signale (:64-77): erstes SIGTERM/INT = nichts Neues, laufenden Auftrag zu Ende; zweites = Kind beenden.

## 4. Was "ein Lane" heute erzwingt - und was NICHT

- Nebenlaeufigkeit: genau ein Run, weil EIN Prozess EINEN Brief nach dem anderen abarbeitet; der flock `.lock` verhindert nur eine zweite INSTANZ desselben Watchers.
- KEIN Repo-Schutz: zwei Runs derselben Repo koennen heute nur deshalb nicht kollidieren, weil es nur einen Run gibt. Mit einer zweiten Lane entfaellt diese implizite Garantie => explizite Repo-Locks noetig.
- KEIN GO-Schutz: "nie zwei GOs gleichzeitig" ergibt sich heute ebenfalls nur aus der Sequentialitaet (GO-Briefs pruefen im Gate "No other GO running/queued", z. B. `20261106T125214Z_GO_forge-noden4merge...`). Mit zwei Lanes braucht es ein Lock.
- Geteilte Zustaende, die eine zweite Lane mit-nutzen muss/darf: `control/STOP` (globaler Kill-Switch soll BEIDE Lanes stoppen), `control/.dispatch.lock`, `state/<K>.session|exec`, `erledigt/`, `ausgang/`, `log/` (flach).
- Lane-spezifisch heute hart verdrahtet (muss pro Lane getrennt werden): `EIN` (:53), `state/.lock` (:58), `state/heartbeat` (:138), `log/postbote.log` (6 Stellen), `state/restart-requested` (:50).

## 5. Tests heute

`tests/test_postbote.sh` (E2E mit Stub-claude/-codex, `FORGE_BASE` im Temp-Verzeichnis, `--once`), `test_heartbeat_env.sh`, `test_restart.sh`, `test_stop.sh`, `test_run_kind.sh`, `test_evidence_order.sh`, `compare_watchers.py` (alter vs. neuer Watcher). Kein Test kennt eine zweite Lane.

## 6. Abgrenzung zu `n5prep` (476d335, Merge in master steht bevor)

n5prep aendert `README.md`, `bin/forge-docker-user.sh`, `tests/test_docker_user_hub.sh`. Lane2 fasst diese drei Dateien NICHT an (Doku in `docs/LANE2.md`, kein README-Eintrag; README-Verweis steht in den offenen Punkten).
