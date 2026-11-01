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
**Deploy (ordered restart):** zuerst bauen/pinnen (forge-core, Migration `0014_run_kind` VOR dem Watcher-Neustart, sonst scheitert die Registrierung eines RUN-Briefs am CHECK), dann Watcher mit `bin/forge-request-restart.sh "S2c RUN-Kind"`
neu starten (wirkt nur zwischen zwei Runs, nie waehrend einer Einheit), `forge-write-result`/`forge-run-job` in den `PATH` der Executoren bzw. an den Watcher-Pfad. Kein Neustart waehrend STOP-Fenstern oder 02:00-05:45 Berlin.
Tests: `tests/test_run_kind.sh` (Grammatik, Allowlist, jede Argument-Regel, Exit-Mapping, Environment, Zeitlimit, ci-gate, Stubs, G27), `tests/test_evidence_order.sh` (= `test_evidence_order_watcher`, Design W-3 am echten Watcher:
Schnappschuss vor jedem `mv` + Abtastung; Reihenfolge Log -> Archiv -> Report; fuer Claude/Codex/RUN/ABGELEHNT/Exit 2).

## `bin/forge-write-result` (F5c Teil 2, Slice S2b; M-100 in S2c)
M-100 (Head-Herkunft): `forge-write-result --nonce <8hex> [--worktree <dir>] [--report <datei>] [--exclusive] <gid>/<key> <json>`. Mit `--worktree` uebernimmt das Werkzeug `head_sha`/`branch` (build), `reviewed_head` (review) bzw. `head_sha` (run)
aus `git rev-parse HEAD` des Worktrees (getrackter Teil muss sauber sein = endgueltiger Commit; ein getippter abweichender Wert => Exit 3 mit beiden Werten) und erzeugt die erste Zeile von `report.md`: `Head: <sha>`.
build/review verlangen `--worktree` und `--report`. Die Aufnahme (forge-core `graph/provenance.py`) prueft Kopfzeile und Head noch einmal gegen die aktuelle Branch-Spitze (`head_not_tip` nach einem spaeteren Commit).
Aeltere Beschreibung (S2b):
`forge-write-result --nonce <8hex> <graph_run_id>/<key> <json-datei>` schreibt die maschinenlesbare Ergebnisdatei einer Graph-Einheit atomar nach `$FORGE_GRAPH_DIR` (Standard `/srv/forge/post/graph`)`/<gid>/<key>/result.json`
(`.tmp` O_EXCL -> fsync -> rename -> fsync Verzeichnis). Prueft nur minimal (Groesse, striktes JSON, `schema`, Pflicht-/erlaubte Schluessel, `nonce`/`graph_run_id`/`key`); die inhaltliche Pruefung und alle Identitaetspruefungen gegen den
Ledger macht der Graph (forge-core `graph/ingest.py`). Exit 0 geschrieben, 2 Aufruf, 3 Datei ungueltig (eine Zeile auf stderr). Das Verzeichnis legt der Graph an. Schluesseltabelle = `forge_core.graph.results.SPEC` (Paritaetstest in forge-core).
Tests: `tests/test_write_result.sh`. Kein Watcher-Neustart noetig (reines Werkzeug); Installation in den `PATH` der Executoren erst nach Slice-Review.
