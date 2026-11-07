# Gemeinsame Hilfen der Lane-Tests (tests/test_lanes.sh, tests/lanes_dryrun_container.sh): Wegwerf-Postfach, Stub-claude mit Zeitleiste, zwei Watcher (Lane 1/2) als Hintergrundprozesse.
# Voraussetzung: $T (Temp-Verzeichnis), $OPSBIN (bin/ der zu testenden Revision) gesetzt. Kein Netz, keine Auth, keine echten Geheimnisse.
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n" "$*"; fi; }

PIDS=()
cleanup_lanes() { local p; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done; command -v pkill >/dev/null && pkill -9 -f "$T/" 2>/dev/null; true; }

# stub-claude: liest den Brief (id:/sleep:-Zeilen), protokolliert START/END mit Nanosekunden und Lane, schlaeft, antwortet
make_stub() {
  cat > "$T/claude" <<'S'
#!/usr/bin/env bash
in="$(cat)"
id="$(sed -n 's/^id: *//p' <<<"$in" | head -n1)"; sl="$(sed -n 's/^sleep: *//p' <<<"$in" | head -n1)"
echo "$(date +%s.%N) START $id ${FORGE_LANE:-1}" >> "$STUB_LOG"
sleep "${sl:-1}"
echo "$(date +%s.%N) END $id ${FORGE_LANE:-1}" >> "$STUB_LOG"
printf '{"type":"result","subtype":"success","session_id":"sid-%s","result":"ok %s","total_cost_usd":0.01}\n' "$id" "$id"
S
  chmod +x "$T/claude"
}

# new_world <name>: frisches FORGE_BASE; setzt BASE, POST, STUB_LOG und die Watcher-Umgebung
new_world() {
  BASE="$T/$1/base"; POST="$BASE/post"; STUB_LOG="$T/$1/stub.log"
  mkdir -p "$POST"/{eingang,ausgang,erledigt,log,state,control} "$BASE/work"; : > "$STUB_LOG"
  export FORGE_BASE="$BASE" STUB_LOG FORGE_MIN_AGE=0 FORGE_POLL=1 FORGE_HB_INTERVAL=1 FORGE_LANE_LOCK_POLL=1 FORGE_LANE_LOCK_LOG=2 CLAUDE_BIN="$T/claude" \
         FORGE_CORE_SECRETS="$T/nosecrets" FORGE_LANE_REPOS_FILE="$T/repos.list" HOME="$T/home"
  mkdir -p "$HOME"
  printf '%s\n' forge-core forge-ops forge-node fundament > "$T/repos.list"
  unset FORGE_LANE FORGE_LANE_LOCK_WAIT
}
# start_lane <N> -> PID in LANE_PID[N]; Ausgabe nach $T/<world>/laneN.out
declare -A LANE_PID
start_lane() {
  local n="$1" out; out="$(dirname "$STUB_LOG")/lane$n.out"
  ( FORGE_LANE="$n" exec bash "$OPSBIN/forge-postbote.sh" >> "$out" 2>&1 ) &
  LANE_PID[$n]=$!; PIDS+=("$!")
}
stop_lane() { local p="${LANE_PID[$1]:-}"; [ -n "$p" ] && { kill -TERM "$p" 2>/dev/null; sleep 0.3; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; LANE_PID[$1]=""; }
inbox() { if [ "$1" = 1 ]; then echo "$POST/eingang"; else echo "$POST/eingang-$1"; fi; }
logf()  { if [ "$1" = 1 ]; then echo "$POST/log/postbote.log"; else echo "$POST/log/postbote-lane$1.log"; fi; }
# brief <lane> <name> <id> <sleep> [repos-Zeile]  (atomar: .tmp -> mv; Punkt-Datei wird nicht gewaehlt)
brief() {
  local d; d="$(inbox "$1")"; mkdir -p "$d"
  { [ -n "${5:-}" ] && echo "$5"; echo "id: $3"; echo "sleep: $4"; } > "$d/.tmp.$2" && mv "$d/.tmp.$2" "$d/$2"
}
# wait_for <sek> <befehl...>
wait_for() { local n="$1" i; shift; for ((i=0;i<n*5;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done; return 1; }
started() { grep -q " START $1 " "$STUB_LOG"; }
ended()   { grep -q " END $1 " "$STUB_LOG"; }
ts_of()   { awk -v k="$1" -v id="$2" '$2==k && $3==id {print $1}' "$STUB_LOG" | head -n1; }   # ts_of START|END <id>
# overlap <idA> <idB>: Exit 0 = die Laufzeiten ueberschneiden sich
overlap() { python3 -I - "$(ts_of START "$1")" "$(ts_of END "$1")" "$(ts_of START "$2")" "$(ts_of END "$2")" <<'PY'
import sys
a0, a1, b0, b1 = map(float, sys.argv[1:5])
sys.exit(0 if a0 < b1 and b0 < a1 else 1)
PY
}
# after <idA> <idB>: Exit 0 = B startet erst nach dem Ende von A
after() { python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$(ts_of START "$2")" "$(ts_of END "$1")"; }
