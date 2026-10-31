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

## `bin/forge-write-result` (F5c Teil 2, Slice S2b)
`forge-write-result --nonce <8hex> <graph_run_id>/<key> <json-datei>` schreibt die maschinenlesbare Ergebnisdatei einer Graph-Einheit atomar nach `$FORGE_GRAPH_DIR` (Standard `/srv/forge/post/graph`)`/<gid>/<key>/result.json`
(`.tmp` O_EXCL -> fsync -> rename -> fsync Verzeichnis). Prueft nur minimal (Groesse, striktes JSON, `schema`, Pflicht-/erlaubte Schluessel, `nonce`/`graph_run_id`/`key`); die inhaltliche Pruefung und alle Identitaetspruefungen gegen den
Ledger macht der Graph (forge-core `graph/ingest.py`). Exit 0 geschrieben, 2 Aufruf, 3 Datei ungueltig (eine Zeile auf stderr). Das Verzeichnis legt der Graph an. Schluesseltabelle = `forge_core.graph.results.SPEC` (Paritaetstest in forge-core).
Tests: `tests/test_write_result.sh`. Kein Watcher-Neustart noetig (reines Werkzeug); Installation in den `PATH` der Executoren erst nach Slice-Review.
