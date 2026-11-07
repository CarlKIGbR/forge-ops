#!/usr/bin/env bash
# fp.sh - RECONSTRUCTED BASELINE (nicht das Original!). Das echte bin/fp.sh liegt auf dem Mac (~/coding/claude_code/Coding_Infrastruktur/bin/fp.sh), nicht auf diesem Host.
# Rekonstruiert nur aus der Doku (KONTEXT_UEBERGABE_AKTIV: `fp.sh send <datei> eingang`, `sendtree`, `pull` -> post/ausgang + post/log/postbote.log, `status`). Dient allein dazu,
# docs/patches/fp_lane2.patch mit `patch --dry-run` zu pruefen; der Owner/die Planerin uebertraegt die drei Aenderungen sinngemaess, wenn Hunks gegen das Original abweichen.
set -eu
HOST="${FP_HOST:-forge}"; REMOTE="${FP_REMOTE:-/srv/forge/post}"; LOCAL="${FP_LOCAL:-./post}"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  send)
    f="${1:?send <datei> [eingang]}"; dest="${2:-eingang}"
    case "$dest" in eingang) ;; *) echo "fp.sh: unbekanntes Ziel '$dest'" >&2; exit 2 ;; esac
    rsync -t "$f" "$HOST:$REMOTE/$dest/" ;;
  sendtree)
    d="${1:?sendtree <ordner> anhang/<K>}"; dest="${2:?}"
    rsync -rt "$d/" "$HOST:$REMOTE/$dest/" ;;
  pull)
    rsync -rt "$HOST:$REMOTE/ausgang/" "$LOCAL/ausgang/"
    rsync -t "$HOST:$REMOTE/log/postbote.log" "$LOCAL/log/" ;;
  status)
    ssh "$HOST" "cd $REMOTE && echo '== eingang' && ls -l eingang | tail -n +2 && echo '== heartbeat' && cat state/heartbeat && echo '== postbote.log' && tail -n 5 log/postbote.log" ;;
  *) echo "Aufruf: fp.sh send|sendtree|pull|status" >&2; exit 2 ;;
esac
