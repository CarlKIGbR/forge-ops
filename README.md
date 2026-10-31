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

## DOCKER-USER fuer den forge-nodehub (N1)
`bin/forge-docker-user.sh --hub` verwaltet einen zweiten, unabhaengigen Regelsatz: TCP/8094 auf 192.168.10.4 nur aus 192.168.10.0/29 und 192.168.30.0/29 (nicht aus dem VPN 10.200.0.0/29), sonst DROP
(forge-node Design 5.1). Eigener Tag `forge-nodehub`, eigener Rollback-Timer-Prefix, eigene Marke `hub-rules-confirmed`; die Edge-Regeln (443/8443) bleiben unveraendert. Ablauf wie beim Edge:
`sudo forge-docker-user.sh --hub` (Timer 300 s) -> Verbindung pruefen -> `sudo forge-docker-user.sh --confirm --hub`. Ein normales `--restore` (Boot) stellt bestaetigte Hub-Regeln mit her.
Nichts davon ist installiert oder angewendet (N1 liefert Code + Tests). Tests: `tests/test_docker_user_hub.sh`.
