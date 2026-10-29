#!/usr/bin/env bash
# M-43: graceful Watcher-Neustart (restart-requested-Flag nur zwischen Runs, SIGTERM-Deferral). Stub-claude, kein Netz.
# Aufruf: tests/test_restart.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/../bin/forge-postbote.sh"
REQ="$HERE/../bin/forge-request-restart.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FORGE_MIN_AGE=0 FORGE_POLL=1 FORGE_HB_INTERVAL=1 STUB_DIR="$T/stub" REQ
CLAUDE_BIN="$T/claude"; CODEX_BIN="$T/codex"; export CLAUDE_BIN CODEX_BIN
mkdir -p "$STUB_DIR"

# Stub: Brief-Inhalt steuert das Verhalten. Marker start.<K> / end.<K> mit Zeitstempel (ns).
cat > "$CLAUDE_BIN" <<'S'
#!/usr/bin/env bash
in=$(cat); k=$(sed -n 's/^K=//p' <<<"$in" | head -n1)
echo "$k" >> "$STUB_DIR/calls"
date +%s%N > "$STUB_DIR/start.$k"
grep -q '^REQUEST$' <<<"$in" && bash "$REQ" "stub-reason" >/dev/null
grep -q '^TOUCHFLAG$' <<<"$in" && { sleep 1; : > "$FORGE_BASE/post/state/restart-requested"; }
grep -q '^SLEEP$' <<<"$in" && sleep 3
date +%s%N > "$STUB_DIR/end.$k"
printf '{"type":"result","subtype":"success","session_id":"sid-%s","result":"ok-%s"}\n' "$k" "$k"
S
printf '#!/usr/bin/env bash\nexit 1\n' > "$CODEX_BIN"
chmod +x "$CLAUDE_BIN" "$CODEX_BIN"

PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
t()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

newbase() { rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"; export FORGE_BASE="$T/base.$1"; mkdir -p "$FORGE_BASE/post/eingang"; E="$FORGE_BASE/post/eingang"; A="$FORGE_BASE/post/ausgang"; ER="$FORGE_BASE/post/erledigt"; LG="$FORGE_BASE/post/log/postbote.log"; FLAG="$FORGE_BASE/post/state/restart-requested"; }
brief() { printf 'K=%s\n%s\n' "$1" "${2:-}" > "$E/BRIEF_$1.md"; touch -d "-${3:-10} seconds" "$E/BRIEF_$1.md"; }
waitfor() { local n=$2 i; for ((i=0;i<n*10;i++)); do eval "$1" && return 0; sleep 0.1; done; return 1; }   # cond sekunden
nrep() { ls "$A"/REPORT_BRIEF_"$1"_* 2>/dev/null | wc -l; }
alive() { kill -0 "$1" 2>/dev/null; }
# wait_exit <pid> <sek> -> setzt EXITRC; 1 wenn Timeout (Prozess wird dann beendet)
wait_exit() { local i; for ((i=0;i<$2*10;i++)); do alive "$1" || { wait "$1"; EXITRC=$?; return 0; }; sleep 0.1; done; kill -KILL "$1" 2>/dev/null; wait "$1" 2>/dev/null; EXITRC=timeout; return 1; }

# --- test_restart_flag_between_runs
newbase 1; brief A REQUEST 20; brief B "" 10
bash "$WATCHER" >/dev/null 2>&1 & P=$!
wait_exit $P 20; t "restart_between_runs: Watcher beendet sich nach A mit rc=0" test "$EXITRC" = 0
t "restart_between_runs: A reportet (rc=0), B noch nicht ausgefuehrt" bash -c "[ $(nrep A) = 1 ] && grep -q 'Exit-Code: 0' $A/REPORT_BRIEF_A_* && [ $(nrep B) = 0 ] && [ -f $E/BRIEF_B.md ]"
RID=$(ls "$ER" | grep BRIEF_A.md | head -n1)
t "restart_between_runs: Flag entfernt, Log 'RESTART requested by <Run-ID von A>'" bash -c "[ ! -e $FLAG ] && grep -q ' RESTART requested by $RID\$' $LG"
bash "$WATCHER" >/dev/null 2>&1 & P=$!
waitfor "[ \$(nrep B) = 1 ]" 20; kill -TERM $P 2>/dev/null; wait_exit $P 10
t "restart_between_runs: neuer Watcher fuehrt B zu Ende (rc=0), je ein Report, A nicht wiederholt" bash -c "grep -q 'Exit-Code: 0' $A/REPORT_BRIEF_B_* && [ $(nrep A) = 1 ] && [ $(nrep B) = 1 ] && [ \"\$(sort $STUB_DIR/calls | tr '\n' ' ')\" = 'A B ' ]"
t "restart_between_runs: Flag-Datei enthaelt reason + requester" bash -c "NEW=\$(mktemp -d); FORGE_BASE=\$NEW FORGE_RUN_ID=rid-1 bash $REQ 'weil noetig' && grep -q '^reason=weil noetig\$' \$NEW/post/state/restart-requested && grep -q '^requester=rid-1\$' \$NEW/post/state/restart-requested"

# --- test_restart_never_during_run
newbase 2; brief A "TOUCHFLAG
SLEEP" 20; brief B "" 10
bash "$WATCHER" >/dev/null 2>&1 & P=$!
waitfor "[ -e $STUB_DIR/start.A ]" 10
waitfor "[ -e $FLAG ]" 10
sleep 0.5
t "never_during_run: Flag existiert, A laeuft weiter (nicht unterbrochen)" bash -c "alive() { kill -0 $P; }; alive && [ ! -e $STUB_DIR/end.A ] && [ -e $FLAG ]"
wait_exit $P 20
t "never_during_run: A mit rc=0 finalisiert (Report, Archiv, Logzeile) vor dem Exit" bash -c "grep -q 'Exit-Code: 0' $A/REPORT_BRIEF_A_* && ls $ER | grep -q BRIEF_A.md && grep -q 'BRIEF_A.md.*rc=0' $LG && [ -e $STUB_DIR/end.A ]"
t "never_during_run: Exit rc=0, danach RESTART-Logzeile, B nicht gestartet" bash -c "[ '$EXITRC' = 0 ] && [ \"\$(grep -n 'rc=0' $LG | head -1 | cut -d: -f1)\" -lt \"\$(grep -n RESTART $LG | head -1 | cut -d: -f1)\" ] && [ ! -e $STUB_DIR/start.B ]"

# --- test_sigterm_deferred
newbase 3; brief A SLEEP 20; brief B "" 10
bash "$WATCHER" >/dev/null 2>&1 & P=$!
waitfor "[ -e $STUB_DIR/start.A ]" 10
kill -TERM $P
wait_exit $P 20
t "sigterm_deferred: A finalisiert (rc=0, Report, Archiv), Watcher rc=0" bash -c "[ '$EXITRC' = 0 ] && grep -q 'Exit-Code: 0' $A/REPORT_BRIEF_A_* && ls $ER | grep -q BRIEF_A.md && grep -q 'ok-A' $A/REPORT_BRIEF_A_* && [ -e $STUB_DIR/end.A ]"
t "sigterm_deferred: B nicht gestartet" bash -c "[ ! -e $STUB_DIR/start.B ] && [ -f $E/BRIEF_B.md ]"
# zweites SIGTERM beendet den laufenden Auftrag
newbase 4; brief A SLEEP 20
bash "$WATCHER" >/dev/null 2>&1 & P=$!
waitfor "[ -e $STUB_DIR/start.A ]" 10
kill -TERM $P; sleep 0.3; kill -TERM $P
wait_exit $P 20
t "sigterm_deferred: zweites SIGTERM beendet A vorzeitig (kein end-Marker), Report vorhanden" bash -c "[ ! -e $STUB_DIR/end.A ] && [ $(nrep A) = 1 ]"

# --- test_no_flag_no_exit
newbase 5; brief A "" 20; brief B "" 10
bash "$WATCHER" >/dev/null 2>&1 & P=$!
waitfor "[ \$(nrep A) = 1 ] && [ \$(nrep B) = 1 ]" 20
sleep 2
t "no_flag_no_exit: beide Briefe erledigt, Watcher laeuft weiter, kein RESTART im Log" bash -c "kill -0 $P && ! grep -q RESTART $LG && [ $(nrep A) = 1 ] && [ $(nrep B) = 1 ]"
kill -TERM $P; wait_exit $P 10
t "no_flag_no_exit: SIGTERM im Leerlauf beendet sofort mit rc=0" test "$EXITRC" = 0

echo "---- $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" = 0 ]
