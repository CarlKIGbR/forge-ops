# forge-ops

`bin/forge-postbote.sh` — Postbote (Watcher) fuer /srv/forge/post. Dateiname-Grammatik siehe Kopfkommentar des Skripts.

## Reserviertes Suffix `.n-<8hex>`
`.n-<8 lowercase hex>` direkt vor `.md` ist der Einwurf-Nonce (wird nie an die CLI weitergereicht, steht in Archivname, Run-ID und `- Nonce:`).
Weil das Modell-Segment gierig matcht, spaltet der Watcher ein endstaendiges `.n-<8hex>` immer als Nonce ab. **Modell-IDs duerfen daher nicht
auf `.n-<8hex>` enden** (z.B. wird `.modell-demo.n-deadbeef.md` als Modell `demo` + Nonce `deadbeef` ausgefuehrt). forge-core (Cockpit/Config) erzwingt das.
Tests: `tests/test_postbote.sh`.

## Graceful Restart (M-43)
`bin/forge-request-restart.sh "<grund>"` legt atomar `post/state/restart-requested` an (reason, requester=`$FORGE_RUN_ID`). Der Watcher prueft das Flag nur zwischen
Runs (nach Finalisierung, vor dem naechsten Brief), loggt `RESTART requested by <id>` und beendet sich mit 0 (systemd `Restart=always`). Laufende Runs werden nie unterbrochen;
`sleep 40; pkill` ist abgeschafft. SIGTERM waehrend eines Runs wird bis zu dessen Ende aufgeschoben (zweites SIGTERM beendet den Auftrag). Details: forge-core `RUNBOOK.md`. Tests: `tests/test_restart.sh`.

## `RUN`-Kind: LLM-freie Auftraege (F5c Teil 2, Slice S2c, Design §4.6)
`RUN_<K>[.n-<8hex>].md` (nur diese Grammatik; `.fortsetzung`/`.exec-`/`.aufwand-`/`.modell-` => ABGELEHNT). Der Inhalt ist ein JSON-Auftrag `{job, args, graph_run_id, key, nonce[, lock_token]}`, den der Watcher an
`bin/forge-run-job` uebergibt - **der einzige Weg** (G27), Jobs auszufuehren: feste Allowlist (`ci-gate`, `merge`, `lock-set`, `deploy-check`, `deploy-stage`, `acceptance`), je Job genau die Argumente, jeder Wert
mit Typ- und Regex-Pruefung (40-Hex-Shas, Repo-Name aus `etc/run-repos.list`, Branch-Muster, ganzzahlige IDs, feste Gate-/Stage-Namen), leeres Environment (kein MCP-Token, kein OTEL), eigene Prozessgruppe, Zeitlimit
(`FORGE_RUN_MAX_SECONDS` Standard 3900 im Watcher; je Job eigenes Limit; bei SIGTERM raeumt forge-run-job die Prozessgruppe auf). Report: `Executor: run`, `- Modell: -`, Body = Auftrag + Ausgabe-Ende (<= 3000 Bytes).
Exit-Codes: 0 Job gelaufen + Ergebnis geschrieben (das **Urteil** steht in `result.json` `ok`), 3 Vorbedingung verletzt (z. B. Head != Branch-Spitze), 4 needs_rebase, 64 Job nicht implementiert (Stub), 65 Auftrag abgelehnt
(eine Zeile auf stderr, nichts ausgefuehrt), 66 Einheiten-Verzeichnis fehlt/unsicher bzw. Ergebnis liegt schon vor, 70 intern/Ergebnis nicht schreibbar, 124 Zeitlimit; sonstige Job-Exits werden durchgereicht.
`result.json` (`graph.run.v1`) und `report.md` schreibt ausschliesslich `forge-write-result --exclusive` (Schema, Nonce, Identitaet, atomar, nie ueber Vorhandenes); der Head (M-100) kommt dabei aus git (`--worktree`).
`bin/jobs/ci-gate` ist echt: Branch-Spitze == `head` (sonst Exit 3), Checkout genau dieses Commits (`git clone --shared`, Quell-Repo unveraendert), Gates laut ops-eigener Tabelle `etc/ci-gates.json` (Gate ohne Eintrag =>
`not_configured` => rot; Gate, das getrackte Dateien aendert => `tree_modified` => rot). Die uebrigen Jobs sind Stubs (Exit 64, `seam_run_jobs`) bis S5b1/S5b2.
**Deploy (ordered restart):** zuerst bauen/pinnen (forge-core, Migration `0016_run_kind` (und `0017_run_orders`) VOR dem Watcher-Neustart, sonst scheitert die Registrierung eines RUN-Briefs am CHECK), dann Watcher mit `bin/forge-request-restart.sh "S2c RUN-Kind"`
neu starten (wirkt nur zwischen zwei Runs, nie waehrend einer Einheit), `forge-write-result`/`forge-run-job` in den `PATH` der Executoren bzw. an den Watcher-Pfad. Kein Neustart waehrend STOP-Fenstern oder 02:00-05:45 Berlin.
Tests: `tests/test_run_kind.sh` (Grammatik, Allowlist, jede Argument-Regel, Exit-Mapping, Environment, Zeitlimit, ci-gate, Stubs, G27), `tests/test_evidence_order.sh` (= `test_evidence_order_watcher`, Design W-3 am echten Watcher:
Schnappschuss vor jedem `mv` + Abtastung; Reihenfolge Log -> Archiv -> Report; fuer Claude/Codex/RUN/ABGELEHNT/Exit 2).

## Gate-Tabelle `etc/ci-gates.json` und `bin/gates/` (F5c Teil 2, Slice S3a)
Die Tabelle ist ops-eigen (nie aus dem Branch); `ci-gate` ersetzt `{ops}` in `argv` durch dieses forge-ops-Checkout, die Hilfsskripte liegen unter `bin/gates/`. Gates laufen im sauberen Checkout mit leerem Environment
(`PATH=/usr/local/bin:/usr/bin:/bin`, `HOME`/`TMPDIR` im Wegwerfbereich, `CI=1`), eigener Prozessgruppe und Zeitlimit; ein Gate ohne Eintrag ist `not_configured` = rot.
- **forge-ops:** `shell_syntax`, `tests` (wie bisher; `shell_syntax` deckt jetzt auch `bin/gates/*` ab).
- **forge-core:** `shell_syntax` (`bin/gates/shell-syntax --min 1`: `bash -n` ueber alle per `git ls-files` getrackten Shell-Skripte, Endung `.sh`/`.bash` oder Shebang bash/sh), `tests` (`bin/gates/forge-core-tests`,
  1500 s: baut `forge-core/tests:gate-<head12>` aus dem Checkout mit den Digest-Pins aus dessen `images.lock`, faehrt die volle Suite im Compose-Projekt `forge-core-gate-<head12>` mit `FORGE_OPS_DIR` = dieses
  Checkout und `FORGE_REQUIRE_OPS=1`, raeumt IMMER auf - Exit, SIGTERM und per abgekoppeltem Waechter auch nach SIGKILL -, fasst nur die eigenen Namen an, reicht den pytest-Exit durch, Ausgabe: letzte 60 Zeilen),
  `gitleaks` (`bin/gates/gitleaks`, 300 s: lokales, per Image-ID gepinntes Tool-Image `forge-tool-gitleaks:build`, `--network none`, read-only, nur Arbeitsbaum ohne Git-Verlauf, Konfiguration `etc/gitleaks.toml`
  statt der des Branches, `.gitleaksignore`/`.gitleaks.toml`/`gitleaks:allow` im Branch wirken nicht; Image fehlt => rot).
- **Bewusst NICHT konfiguriert (=> `not_configured` => rot):** `lint`, `format` (kein Linter auf dem Host, forge-core hat keine Lint-/Format-Konfiguration - kein Fake-Gate), `diff_coverage`, `migration_class` (kein Werkzeug)
  sowie jedes Gate fuer jedes andere Repo (z. B. `forge-docs`). Zeitlimits: je Gate max. 3600 s, Job-Limit von `ci-gate` 3600 s, `FORGE_RUN_MAX_SECONDS` 3900 s (Summe der konfigurierten forge-core-Gates 1920 s).
Tests: `tests/test_ci_gates_table.sh` (Tabelle, `shell_syntax` gruen/rot, `gitleaks` am echten lokalen Image, `tests`-Gate mit gestubbtem `docker`: abgeleitete Namen, Aufraeumen bei Exit/SIGTERM/SIGKILL, Exit-Weitergabe).

## `bin/forge-write-result` (F5c Teil 2, Slice S2b; M-100 in S2c)
M-100 (Head-Herkunft): `forge-write-result --nonce <8hex> [--worktree <dir>] [--report <datei>] [--exclusive] <gid>/<key> <json>`. Mit `--worktree` uebernimmt das Werkzeug `head_sha`/`branch` (build), `reviewed_head` (review) bzw. `head_sha` (run)
aus `git rev-parse HEAD` des Worktrees (getrackter Teil muss sauber sein = endgueltiger Commit; ein getippter abweichender Wert => Exit 3 mit beiden Werten) und erzeugt die erste Zeile von `report.md`: `Head: <sha>`.
build/review verlangen `--worktree` und `--report`. Die Aufnahme (forge-core `graph/provenance.py`) prueft Kopfzeile und Head noch einmal gegen die aktuelle Branch-Spitze (`head_not_tip` nach einem spaeteren Commit).
Aeltere Beschreibung (S2b):
`forge-write-result --nonce <8hex> <graph_run_id>/<key> <json-datei>` schreibt die maschinenlesbare Ergebnisdatei einer Graph-Einheit atomar nach `$FORGE_GRAPH_DIR` (Standard `/srv/forge/post/graph`)`/<gid>/<key>/result.json`
(`.tmp` O_EXCL -> fsync -> rename -> fsync Verzeichnis). Prueft nur minimal (Groesse, striktes JSON, `schema`, Pflicht-/erlaubte Schluessel, `nonce`/`graph_run_id`/`key`); die inhaltliche Pruefung und alle Identitaetspruefungen gegen den
Ledger macht der Graph (forge-core `graph/ingest.py`). Exit 0 geschrieben, 2 Aufruf, 3 Datei ungueltig (eine Zeile auf stderr). Das Verzeichnis legt der Graph an. Schluesseltabelle = `forge_core.graph.results.SPEC` (Paritaetstest in forge-core).
Tests: `tests/test_write_result.sh`. Kein Watcher-Neustart noetig (reines Werkzeug); Installation in den `PATH` der Executoren erst nach Slice-Review.

## RUN-Autoritaet (ADR-028, S2c rework 1)
`bin/forge-run-job` startet einen Auftrag nur, wenn der Graph ihn bestellt hat: unmittelbar vor dem Start wird der Dispatch-Eintrag (`core.graph_run_orders`: Nonce, graph_run_id, sha256 der Auftragsdatei, Zustand `published`) atomar auf `running` gesetzt
(`docker exec -i $FORGE_PG_CONTAINER psql ...`, Standard `forge-postgres-1`; Test: `FORGE_RUN_ORDER_PSQL` = JSON-Liste des psql-Aufrufs). Kein Eintrag / andere sha256 / anderer graph_run_id / schon verbraucht => Exit 65, Datenbank nicht erreichbar => Exit 69, jeweils OHNE Wirkung
(auch wenn der Watcher die Datei vor dem Importer aufgreift). Der Dateiname muss `...n-<nonce>.md` mit dem Nonce des Auftrags tragen. Tests: `tests/test_run_kind.sh` (Abschnitt 7b, mit `tests/fake-psql` als Nachbildung der Verbrauchs-Semantik); die echte DB-Semantik pruefen die Kern-Tests `test_f5c2_s2c_runorders.py`.

## DOCKER-USER fuer den forge-nodehub (N1)
`bin/forge-docker-user.sh --hub` verwaltet einen zweiten, unabhaengigen Regelsatz: TCP/8094 auf 192.168.10.4 nur aus 192.168.10.0/29 und 192.168.30.0/29 (nicht aus dem VPN 10.200.0.0/29), sonst DROP
(forge-node Design 5.1). Eigener Tag `forge-nodehub`, eigener Rollback-Timer-Prefix, eigene Marke `hub-rules-confirmed`; die Edge-Regeln (443/8443) bleiben unveraendert. Ablauf wie beim Edge:
`sudo forge-docker-user.sh --hub` (Timer 300 s) -> Verbindung pruefen -> `sudo forge-docker-user.sh --confirm --hub`. Ein normales `--restore` (Boot) stellt bestaetigte Hub-Regeln mit her - **aber die Unit `forge-docker-user.service` fuehrt die Root-Kopie `/usr/local/sbin/forge-docker-user.sh` aus, nicht das Repo-Script**:
nach dem Merge muss einmal `sudo <repo>/bin/forge-docker-user.sh --install-unit` laufen (ersetzt die Kopie; Edge-Regeln und -Marke bleiben unberuehrt, nichts wird gestartet). `--hub` und `--confirm --hub` brechen ohne identische
Boot-Kopie ab (Exit 1, keine Regel, keine Marke), damit der Hub-Port nach einem Reboot nie offen zurueckkommt. Pruefung: `sudo /usr/local/sbin/forge-docker-user.sh --dry-run --restore | grep -c forge-nodehub` = 3 (nach `--confirm --hub`).
Bekanntes Restfenster: beim Boot startet Docker den Hub (`restart: unless-stopped`) vor der Unit; die 8094-Regeln folgen Sekunden spaeter. Fehlschlag des Hub-Restore: Port 8094 ist dann OFFEN (nur mTLS davor) - die Unit meldet es auf stderr.
Nichts davon ist installiert oder angewendet (N1 liefert Code + Tests). Tests: `tests/test_docker_user_hub.sh`.
