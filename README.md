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
