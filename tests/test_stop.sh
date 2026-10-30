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

echo "---- $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" = 0 ]
