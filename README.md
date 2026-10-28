# forge-ops

`bin/forge-postbote.sh` — Postbote (Watcher) fuer /srv/forge/post. Dateiname-Grammatik siehe Kopfkommentar des Skripts.

## Reserviertes Suffix `.n-<8hex>`
`.n-<8 lowercase hex>` direkt vor `.md` ist der Einwurf-Nonce (wird nie an die CLI weitergereicht, steht in Archivname, Run-ID und `- Nonce:`).
Weil das Modell-Segment gierig matcht, spaltet der Watcher ein endstaendiges `.n-<8hex>` immer als Nonce ab. **Modell-IDs duerfen daher nicht
auf `.n-<8hex>` enden** (z.B. wird `.modell-demo.n-deadbeef.md` als Modell `demo` + Nonce `deadbeef` ausgefuehrt). forge-core (Cockpit/Config) erzwingt das.
Tests: `tests/test_postbote.sh`.
