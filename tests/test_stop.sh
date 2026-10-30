#!/usr/bin/env bash
# F5b: Watcher pausiert bei STOP, forge-stop/forge-release nehmen das Dispatch-flock. Stub-claude, kein Netz.
# Aufruf: tests/test_stop.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/../bin/forge-postbote.sh"; FSTOP="$HERE/../bin/forge-stop"; FREL="$HERE/../bin/forge-release"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FORGE_BASE="$T/base" FORGE_MIN_AGE=0 FORGE_POLL=1 FORGE_HB_INTERVAL=1
CLAUDE_BIN="$T/claude"; CODEX_BIN="$T/codex"; export CLAUDE_BIN CODEX_BIN STUB_LOG="$T/stub.log"
printf '#!/usr/bin/env bash\necho "called" >> "$STUB_LOG"; cat >/dev/null\nprintf %%s\\\\n '"'"'{"type":"result","subtype":"success","session_id":"sid","result":"ok"}'"'"'\n' > "$CLAUDE_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CODEX_BIN"; chmod +x "$CLAUDE_BIN" "$CODEX_BIN"
P="$FORGE_BASE/post"; CTRL="$P/control"; mkdir -p "$P/eingang" "$CTRL"; : > "$STUB_LOG"
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# --- test_watcher_skips_while_stop ---
printf 'x\n' > "$P/eingang/BRIEF_S1.md"; : > "$CTRL/STOP"
bash "$WATCHER" --once
check "watcher_skips_while_stop: Brief bleibt in eingang"   test -f "$P/eingang/BRIEF_S1.md"
check "watcher_skips_while_stop: Executor nicht gerufen"    test ! -s "$STUB_LOG"
check "watcher_skips_while_stop: kein Report/Archiv"         bash -c "! ls '$P'/ausgang/REPORT_* '$P'/erledigt/* 2>/dev/null | grep -q ."
check "watcher_skips_while_stop: Log 'paused by STOP'"       grep -q 'paused by STOP' "$P/log/postbote.log"
# Dauerbetrieb: pausiert, pollt weiter, startet nach Freigabe (Release waehrend der Watcher laeuft)
bash "$WATCHER" > "$T/w.out" 2>&1 & W=$!
sleep 3
check "pausiert im Dauerbetrieb (nach 3 s weiter nichts gestartet)" test ! -s "$STUB_LOG"
check "Pause nur einmal geloggt"                              bash -c "[ \$(grep -c 'paused by STOP' '$P/log/postbote.log') -le 2 ]"
bash "$FREL" >/dev/null
for i in 1 2 3 4 5 6 7 8; do [ -s "$STUB_LOG" ] && break; sleep 1; done
check "STOP entfernt: Brief laeuft"                            test -s "$STUB_LOG"
check "STOP entfernt: Brief archiviert + Report"              bash -c "ls '$P'/erledigt/*BRIEF_S1.md >/dev/null && ls '$P'/ausgang/REPORT_BRIEF_S1_* >/dev/null"
check "Log 'resumed'"                                           grep -q 'resumed' "$P/log/postbote.log"
# STOP laeuft nicht laufende Briefe tot: Stub schlaeft, STOP waehrenddessen -> Brief wird fertig, naechster bleibt liegen
printf '#!/usr/bin/env bash\ncat >/dev/null; echo called >> "$STUB_LOG"; sleep 2\nprintf %%s\\\\n '"'"'{"type":"result","subtype":"success","session_id":"s","result":"ok"}'"'"'\n' > "$CLAUDE_BIN"
: > "$STUB_LOG"; printf 'a\n' > "$P/eingang/BRIEF_S2.md"; sleep 2; : > "$CTRL/STOP"; printf 'b\n' > "$P/eingang/BRIEF_S3.md"; sleep 5
check "laufender Brief wird nicht abgebrochen (S2 fertig)"    bash -c "ls '$P'/ausgang/REPORT_BRIEF_S2_* >/dev/null && grep -q 'Exit-Code: 0' '$P'/ausgang/REPORT_BRIEF_S2_*"
check "nachfolgender Brief startet nicht (S3 liegt)"          test -f "$P/eingang/BRIEF_S3.md"
kill -TERM $W 2>/dev/null; wait $W 2>/dev/null
rm -f "$CTRL/STOP"

# --- forge-stop / forge-release nehmen das flock ---
LOCK="$CTRL/.dispatch.lock"
flock "$LOCK" sleep 2 & H=$!            # simulierter laufender Dispatch (haelt das Lock)
sleep 0.3
bash "$FSTOP" "test" > "$T/stop.out" 2>&1 & S=$!
sleep 0.7
check "forge-stop wartet auf das Lock (STOP noch nicht da)"   test ! -e "$CTRL/STOP"
wait $S; rc=$?
check "forge-stop setzt STOP nach Freigabe des Locks"        test -f "$CTRL/STOP"
check "forge-stop Exit 0"                                      test "$rc" = 0
check "STOP-Inhalt mit Zeit/Benutzer/Grund"                   grep -q 'STOP .* by host:.*(test)' "$CTRL/STOP"
flock "$LOCK" sleep 2 & H2=$!; sleep 0.3
bash "$FREL" >/dev/null 2>&1 & R=$!; sleep 0.7
check "forge-release wartet ebenfalls (STOP bleibt)"          test -f "$CTRL/STOP"
wait $R; check "forge-release entfernt STOP nach Lock-Freigabe" test ! -e "$CTRL/STOP"
flock "$LOCK" sleep 3 & H3=$!; sleep 0.3
FORGE_LOCK_TIMEOUT=1 bash "$FSTOP" >/dev/null 2>&1; rc=$?
check "forge-stop ohne Lock-Erhalt: Exit 1, kein STOP"        bash -c "[ $rc = 1 ] && [ ! -e '$CTRL/STOP' ]"
wait $H3 2>/dev/null
check "forge-release idempotent"                                bash "$FREL"
check "forge-stop legt fehlendes control/ an"                   bash -c "rm -rf '$CTRL'; bash '$FSTOP' >/dev/null && test -f '$CTRL/STOP'"


# --- Rework 3: STOP zwischen Auswahl und Start eines bereits laufenden Watchers ---
fresh() {  # frische Basis + Stub (zaehlt Aufrufe); setzt P, CTRL, LOCK
  [ -n "${W:-}" ] && { kill -TERM $W 2>/dev/null; wait $W 2>/dev/null; W=""; }
  export FORGE_BASE="$T/b$1"; P="$FORGE_BASE/post"; CTRL="$P/control"; LOCK="$CTRL/.dispatch.lock"
  mkdir -p "$P/eingang" "$CTRL"; : > "$LOCK"; : > "$STUB_LOG"
  printf '#!/usr/bin/env bash\ncat >/dev/null; echo called >> "$STUB_LOG"\nprintf %%s\\n '"'"'{"type":"result","subtype":"success","session_id":"s","result":"ok"}'"'"'\n' > "$CLAUDE_BIN"
  H="$T/h$1"; mkdir -p "$H"
  printf '#!/usr/bin/env bash\n: > "%s/sel.entered"\nwhile [ ! -e "%s/sel.go" ]; do sleep 0.1; done\n' "$H" "$H" > "$H/after_select"
  printf '#!/usr/bin/env bash\n: > "%s/claim.entered"\nwhile [ ! -e "%s/claim.go" ]; do sleep 0.1; done\n' "$H" "$H" > "$H/in_claim"
  chmod +x "$H/after_select" "$H/in_claim"
}
waitfor() { for i in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
W=""

# test_watcher_running_stop_between_select_and_start
fresh 1
FORGE_HOOK_AFTER_SELECT="$H/after_select" bash "$WATCHER" > "$T/w1.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_R1.md"
check "select/start: Watcher hat den Brief gewaehlt (Hook erreicht)" waitfor "$H/sel.entered"
bash "$FSTOP" "gap" >/dev/null                      # Lock ist frei (Watcher steht im Hook, ausserhalb des Lock-Abschnitts) -> STOP sofort gesetzt
: > "$H/sel.go"; sleep 2
check "select/start: Brief NICHT gestartet (Stub nie gerufen)"   test ! -s "$STUB_LOG"
check "select/start: Brief bleibt in eingang"                      test -f "$P/eingang/BRIEF_R1.md"
check "select/start: kein Report, kein Archiv"                     bash -c "! ls '$P'/ausgang/REPORT_* '$P'/erledigt/* 2>/dev/null | grep -q ."
check "select/start: Log 'paused by STOP'"                         grep -q 'paused by STOP' "$P/log/postbote.log"
bash "$FREL" >/dev/null
for i in $(seq 1 80); do [ -s "$STUB_LOG" ] && break; sleep 0.1; done
check "select/start: nach forge-release laeuft der Brief"          test -s "$STUB_LOG"
check "select/start: ...und wird archiviert"                       bash -c "sleep 1; ls '$P'/erledigt/*BRIEF_R1.md >/dev/null"

# test_watcher_running_touch_before_locked_check
fresh 2
FORGE_HOOK_AFTER_SELECT="$H/after_select" bash "$WATCHER" > "$T/w2.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_R2.md"
waitfor "$H/sel.entered"
: > "$CTRL/STOP"                                    # rohes touch, ohne forge-stop, vor der gesperrten Pruefung
: > "$H/sel.go"; sleep 2
check "touch vor gesperrter Pruefung: nicht gestartet"            test ! -s "$STUB_LOG"
check "touch vor gesperrter Pruefung: Brief liegt in eingang"     test -f "$P/eingang/BRIEF_R2.md"
check "touch vor gesperrter Pruefung: Log paused"                 grep -q 'paused by STOP' "$P/log/postbote.log"

# test_watcher_lock_held_during_claim
fresh 3
FORGE_HOOK_IN_CLAIM="$H/in_claim" bash "$WATCHER" > "$T/w3.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_R3.md"
check "claim: Watcher steht im gesperrten Abschnitt"              waitfor "$H/claim.entered"
bash "$FSTOP" "during-claim" >/dev/null 2>&1 & S=$!
sleep 0.8
check "claim: forge-stop blockiert (STOP noch nicht gesetzt)"     test ! -e "$CTRL/STOP"
check "claim: Brief noch nicht gestartet"                         test ! -s "$STUB_LOG"
: > "$H/claim.go"                                   # Watcher setzt den Start fort: Executor spawnen, Lock freigeben
wait $S
check "claim: danach setzt forge-stop STOP"                       test -f "$CTRL/STOP"
for i in $(seq 1 50); do [ -s "$STUB_LOG" ] && break; sleep 0.1; done
check "claim: Brief startete vor STOP (laeuft/fertig, nicht abgebrochen)" bash -c "test -s '$STUB_LOG' && sleep 1 && ls '$P'/ausgang/REPORT_BRIEF_R3_* >/dev/null && grep -q 'Exit-Code: 0' '$P'/ausgang/REPORT_BRIEF_R3_*"
check "claim: Lock nach dem Spawn wieder frei"                    bash -c "flock -n -w 2 '$LOCK' true"
# langer Lauf haelt das Lock NICHT: forge-stop waehrend der Executor laeuft kehrt sofort zurueck
fresh 4
printf '#!/usr/bin/env bash\ncat >/dev/null; echo called >> "$STUB_LOG"; sleep 4\nprintf %%s\\n '"'"'{"type":"result","subtype":"success","session_id":"s","result":"ok"}'"'"'\n' > "$CLAUDE_BIN"
bash "$WATCHER" > "$T/w4.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_R4.md"; for i in $(seq 1 50); do [ -s "$STUB_LOG" ] && break; sleep 0.1; done
t0=$(date +%s); FORGE_LOCK_TIMEOUT=2 bash "$FSTOP" >/dev/null 2>&1; rc=$?; t1=$(date +%s)
check "laufender Brief haelt das Lock nicht (forge-stop sofort, rc 0)" bash -c "[ $rc = 0 ] && [ $((t1-t0)) -le 1 ]"
kill -TERM $W 2>/dev/null; wait $W 2>/dev/null; W=""


# --- Rework 4: fehlendes control/ : fail closed, nie ohne Lock starten ---
fresh_nocontrol() { fresh "$1"; rm -rf "$CTRL"; }

# test_watcher_missing_control_dir_creates_and_locks
fresh_nocontrol 5
FORGE_HOOK_IN_CLAIM="$H/in_claim" bash "$WATCHER" > "$T/w5.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_C1.md"
check "missing control: Watcher erreicht den gesperrten Abschnitt" waitfor "$H/claim.entered"
check "missing control: control/ angelegt, Modus 2775"             bash -c "[ -d '$CTRL' ] && [ \"\$(stat -c %a '$CTRL')\" = 2775 ]"
check "missing control: Lock wird wirklich gehalten"               bash -c "! flock -n '$LOCK' true"
check "missing control: noch nichts gestartet"                      test ! -s "$STUB_LOG"
: > "$H/claim.go"
for i in $(seq 1 60); do [ -s "$STUB_LOG" ] && break; sleep 0.1; done
check "missing control: Brief startet nach dem gesperrten Abschnitt" test -s "$STUB_LOG"

# test_watcher_control_uncreatable_does_not_start (Elternverzeichnis read-only)
if [ "$(id -u)" = 0 ]; then echo "SKIP  uncreatable (root ignoriert Dateirechte)"; else
fresh_nocontrol 6
mkdir -p "$P/log" "$P/state" "$P/ausgang" "$P/erledigt"
chmod 555 "$P"
bash "$WATCHER" > "$T/w6.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_C2.md"; sleep 3
check "uncreatable: Brief nicht gestartet"                        test ! -s "$STUB_LOG"
check "uncreatable: Brief bleibt in eingang"                      test -f "$P/eingang/BRIEF_C2.md"
check "uncreatable: Log 'control unavailable'"                    grep -q 'control unavailable' "$P/log/postbote.log"
check "uncreatable: Watcher pollt weiter (lebt, Heartbeat frisch)" bash -c "kill -0 $W && [ \$(( \$(date +%s) - \$(date -u -d \"\$(cat '$P/state/heartbeat')\" +%s) )) -le 5 ]"
chmod 755 "$P"                                                     # Problem behoben -> naechster Poll startet
for i in $(seq 1 60); do [ -s "$STUB_LOG" ] && break; sleep 0.1; done
check "uncreatable: nach Behebung startet der Brief (control/ angelegt)" bash -c "test -s '$STUB_LOG' && test -d '$CTRL'"
chmod 755 "$P" 2>/dev/null
fi

# test_forge_stop_missing_control_dir_serialized
fresh_nocontrol 7
FORGE_HOOK_AFTER_SELECT="$H/after_select" bash "$WATCHER" > "$T/w7.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_C3.md"
waitfor "$H/sel.entered"
check "forge-stop ohne control/: control/ noch weg (Watcher steht im Hook)" test ! -d "$CTRL"
bash "$FSTOP" "gap-nodir" >/dev/null 2>&1; rc=$?
check "forge-stop ohne control/: Exit 0, control/ + Lock-Datei + STOP angelegt" bash -c "[ $rc = 0 ] && [ -f '$LOCK' ] && [ -f '$CTRL/STOP' ] && [ \"\$(stat -c %a '$CTRL')\" = 2775 ]"
: > "$H/sel.go"; sleep 2
check "forge-stop ohne control/: Brief NICHT gestartet"            test ! -s "$STUB_LOG"
check "forge-stop ohne control/: Brief bleibt in eingang"          test -f "$P/eingang/BRIEF_C3.md"
bash "$FREL" >/dev/null
for i in $(seq 1 60); do [ -s "$STUB_LOG" ] && break; sleep 0.1; done
check "forge-stop ohne control/: nach forge-release startet er"    test -s "$STUB_LOG"
# forge-stop liefert 0 nur mit gehaltenem Lock: haelt der Watcher es (control/ vom Watcher angelegt), wartet/scheitert forge-stop
fresh_nocontrol 8
FORGE_HOOK_IN_CLAIM="$H/in_claim" bash "$WATCHER" > "$T/w8.out" 2>&1 & W=$!
sleep 1; printf 'x\n' > "$P/eingang/BRIEF_C4.md"; waitfor "$H/claim.entered"
FORGE_LOCK_TIMEOUT=1 bash "$FSTOP" >/dev/null 2>&1; rc=$?
check "forge-stop: Exit 1 und kein STOP, solange der Watcher das Lock haelt" bash -c "[ $rc = 1 ] && [ ! -e '$CTRL/STOP' ]"
: > "$H/claim.go"
kill -TERM $W 2>/dev/null; wait $W 2>/dev/null; W=""
check "forge-stop: STOP-Schreiben steht nach flock im Skript"      bash -c "[ \$(grep -n 'flock -w' '$FSTOP' | head -1 | cut -d: -f1) -lt \$(grep -n '> \"\$CTRL/STOP\"' '$FSTOP' | head -1 | cut -d: -f1) ]"

echo "---- $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" = 0 ]
