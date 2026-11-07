#!/usr/bin/env bash
# forge-request-restart.sh "<grund>" - bittet den Postboten um einen Neustart NACH dem aktuellen Run (M-43).
# Legt $FORGE_BASE/post/state/restart-requested (Lane 2: restart-requested-lane2) atomar an (Inhalt: reason, requester = FORGE_RUN_ID, time).
# Der Watcher prueft das Flag nur zwischen Runs (nach Report/Archiv/Logzeile/Heartbeat, vor dem naechsten Brief),
# entfernt es, loggt "RESTART requested by <id>" und beendet sich mit 0; systemd (Restart=always) startet ihn neu.
# Ein laufender Auftrag wird nie unterbrochen. Als LETZTE Aktion eines Executors aufrufen; nie pkill/kill verwenden.
set -eu
BASE="${FORGE_BASE:-/srv/forge}"
STATE="$BASE/post/state"
# Lane 2 (FORGE_LANE=2 in der Umgebung des Executors, vom Watcher gesetzt): eigenes Flag, der Watcher der anderen Lane bleibt unberuehrt. Lane 1 / ohne FORGE_LANE: wie bisher.
flagsuf=""; case "${FORGE_LANE:-1}" in 1) ;; 2) flagsuf="-lane2" ;; *) echo "FORGE_LANE=${FORGE_LANE} nicht unterstuetzt" >&2; exit 2 ;; esac
reason="${1:-}"
[ -n "$reason" ] || { echo "Aufruf: $0 \"<grund>\"" >&2; exit 2; }
reason="${reason//$'\n'/ }"; reason="${reason//$'\r'/ }"
requester="${FORGE_RUN_ID:-manual-${USER:-$(id -un)}-$$}"
mkdir -p "$STATE"
tmp=$(mktemp "$STATE/.restart.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf 'reason=%s\nrequester=%s\ntime=%s\n' "$reason" "$requester" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
chmod 0664 "$tmp"
mv -f "$tmp" "$STATE/restart-requested$flagsuf"
trap - EXIT
echo "Neustart angefordert (requester=$requester): wirksam nach Abschluss des laufenden Runs."
