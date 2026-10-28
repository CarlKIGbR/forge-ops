#!/usr/bin/env bash
# F2_switch_watcher.sh - vom Owner mit sudo auszufuehren (NICHT durch forge).
# Schaltet forge-postbote.service auf den selbst wartbaren Watcher in forge-ops um:
#   /srv/forge/work/forge-ops/bin/forge-postbote.sh   (statt /usr/local/bin/forge-postbote.sh)
# Rollback: rm /etc/systemd/system/forge-postbote.service.d/10-forge-ops.conf; systemctl daemon-reload; systemctl restart forge-postbote
set -euo pipefail

UNIT=forge-postbote.service
NEW=/srv/forge/work/forge-ops/bin/forge-postbote.sh
DROPDIR=/etc/systemd/system/$UNIT.d
DROP=$DROPDIR/10-forge-ops.conf
CODEXDIR=/srv/forge/home/.local/bin
WAIT_MAX=${WAIT_MAX:-1800}   # Sekunden (30 min)

[ "$(id -u)" = 0 ] || { echo "Bitte mit sudo ausfuehren." >&2; exit 1; }
[ -x "$NEW" ] || { echo "FEHLER: $NEW fehlt oder nicht ausfuehrbar." >&2; exit 1; }
bash -n "$NEW" || { echo "FEHLER: Syntaxcheck von $NEW schlug fehl." >&2; exit 1; }
[ -x "$CODEXDIR/codex" ] && echo "codex gefunden: $("$CODEXDIR/codex" --version 2>&1 | head -n1)" \
  || echo "HINWEIS: $CODEXDIR/codex nicht ausfuehrbar."

# PATH pruefen: enthaelt die Unit $CODEXDIR bereits?
CURPATH=$(systemctl show "$UNIT" -p Environment --value | tr ' ' '\n' | sed -n 's/^PATH=//p' | tail -n1)
case ":$CURPATH:" in
  *":$CODEXDIR:"*) NEED_PATH=0; echo "PATH der Unit enthaelt $CODEXDIR bereits - unveraendert." ;;
  *) NEED_PATH=1; echo "PATH der Unit ohne $CODEXDIR - wird im Drop-in ergaenzt." ;;
esac

mkdir -p "$DROPDIR"
{
  echo "# verwaltet von F2_switch_watcher.sh - Watcher kommt aus dem Git-Repo forge-ops"
  echo "[Service]"
  echo "ExecStart="
  echo "ExecStart=$NEW"
  [ "$NEED_PATH" = 1 ] && echo "Environment=PATH=$CODEXDIR:${CURPATH:-/usr/local/bin:/usr/bin:/bin}"
} > "$DROP"
chmod 644 "$DROP"
echo "Drop-in geschrieben: $DROP"; sed 's/^/    /' "$DROP"
systemctl daemon-reload
echo "systemctl daemon-reload: ok"

# Laeuft gerade ein Auftrag? Der Watcher haelt state/.lock dauerhaft (auch im Leerlauf) -
# flock -n zeigt daher nur, ob ueberhaupt ein Watcher lebt. "Aktiv" = in der cgroup der Unit
# existiert ein Prozess ausser Haupt-Watcher und sleep (also claude/codex samt Hilfsprozessen).
LOCK=/srv/forge/post/state/.lock
busy() {
  local cg mp p c
  cg=$(systemctl show "$UNIT" -p ControlGroup --value); mp=$(systemctl show "$UNIT" -p MainPID --value)
  [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ] || return 1
  while read -r p; do
    [ "$p" = "$mp" ] && continue
    c=$(cat "/proc/$p/comm" 2>/dev/null) || continue
    [ "$c" = sleep ] && continue
    return 0
  done < "/sys/fs/cgroup$cg/cgroup.procs"
  return 1
}

if ! systemctl is-active --quiet "$UNIT"; then
  echo "Service war nicht aktiv - starte ihn."
  systemctl start "$UNIT"; ACTION=gestartet
elif ( exec 8>"$LOCK"; flock -n 8 ); then
  echo "state/.lock ist frei (kein Watcher-Prozess) - restart."
  systemctl restart "$UNIT"; ACTION=neu_gestartet
else
  waited=0
  while busy; do
    if [ "$waited" -ge "$WAIT_MAX" ]; then
      echo "Auftrag laeuft nach ${WAIT_MAX}s noch - KEIN Restart. Drop-in ist aktiv ab dem naechsten Restart."
      echo "Spaeter erneut ausfuehren oder: sudo systemctl restart $UNIT"
      exit 3
    fi
    [ $((waited % 60)) = 0 ] && echo "Auftrag aktiv - warte (${waited}s von ${WAIT_MAX}s) ..."
    sleep 10; waited=$((waited + 10))
  done
  echo "Kein Auftrag aktiv (gewartet: ${waited}s) - restart."
  systemctl restart "$UNIT"; ACTION=neu_gestartet
fi

sleep 2
echo "Ergebnis: $ACTION; is-active=$(systemctl is-active "$UNIT")"
echo "ExecStart jetzt: $(systemctl show "$UNIT" -p ExecStart --value | grep -o 'path=[^ ;]*' | head -n1)"
echo "Fertig. Ab jetzt aktualisiert forge den Watcher per git in /srv/forge/work/forge-ops (Restart noetig fuer Aktivierung)."
