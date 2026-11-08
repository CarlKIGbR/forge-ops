#!/usr/bin/env bash
# Mutationsprobe der Lane-Tests: je ein gezielter Defekt in einer Kopie von bin/ muss von den zustaendigen Abschnitten von tests/test_lanes.sh gefangen werden (Exit != 0).
# Aufruf: tests/mutation_lanes.sh   (Exit 0 = jeder Mutant wurde erkannt)  Dauer ~1 min je Mutant.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
caught=0; missed=0
mutant() {   # name "sections" datei sed-ausdruck
  local name="$1" secs="$2" file="$3" expr="$4"
  rm -rf "$T/bin"; cp -r "$HERE/../bin" "$T/bin"
  sed -i -E "$expr" "$T/bin/$file"
  if cmp -s "$T/bin/$file" "$HERE/../bin/$file"; then echo "KEIN EFFEKT  $name (Muster passt nicht)"; missed=$((missed+1)); return; fi
  if LANE_TEST_BIN="$T/bin" LANE_TEST_SECTIONS="$secs" bash "$HERE/test_lanes.sh" >"$T/out" 2>&1; then echo "UEBERLEBT    $name"; missed=$((missed+1))
  else echo "erkannt      $name ($(grep -c '^FAIL' "$T/out") FAIL)"; caught=$((caught+1)); fi
}
mutant "kein Repo-Lock"                  "3"   forge-lanes.sh 's/PLAN_LOCKS\+=\("X:repo-\$r"\)/:/'
mutant "kein Deploy-Lock fuer GO"        "4"   forge-lanes.sh 's/\[ "\$art" = GO \] && deploy=1/:/'
mutant "unbekanntes Repo sperrt nicht"   "3"   forge-lanes.sh 's/lane_known_repo "\$tok" \|\| \{ echo ALL; return 0; \}/:/'
mutant "fehlende repos:-Zeile => NONE"   "3"   forge-lanes.sh 's/\[ "\$found" = 0 \] && \{ echo ALL; return 0; \}/[ "$found" = 0 ] \&\& { echo NONE; return 0; }/'
mutant "kein K-Lock"                     "3"   forge-lanes.sh 's/\[ "\$art" != RUN \] && PLAN_LOCKS\+=\("X:k-\$k"\)/:/'
mutant "gemeinsamer Heartbeat"           "5"   forge-lanes.sh 's/HBF="\$STATE\/heartbeat\$LANE_SUF"/HBF="$STATE\/heartbeat"/; s/HBTMP="\$STATE\/\.heartbeat\$LANE_SUF\.tmp"/HBTMP="$STATE\/.heartbeat.tmp"/'
mutant "gemeinsamer Logstrom"            "1"   forge-lanes.sh 's/LOGF="\$LOGD\/postbote-lane\$LANE\.log"/LOGF="$LOGD\/postbote.log"/'
mutant "gemeinsamer Lane-flock"          "2"   forge-lanes.sh 's/LANE_LOCK_FILE="\$STATE\/\.lock\$LANE_SUF"/LANE_LOCK_FILE="$STATE\/.lock"/'
mutant "Sperren im Kind nicht geschlossen" "6" forge-postbote.sh 's/\( lane_close_fds; /( /'
mutant "kein Peer-Handshake"             "7"   forge-lanes.sh 's/^lane_peer_ok\(\) \{/lane_peer_ok() { return 0;/'
mutant "Warten ohne Zeitgrenze"          "8"   forge-lanes.sh 's/\[ "\$waited" -ge "\$dl" \]/false/'
mutant "kein Abbruch bei SIGTERM"        "8"   forge-lanes.sh 's/\[ "\$\{STOP:-0\}" = 1 \]/false/'
mutant "Routing aus"                     "1"   forge-lanes.sh 's/^lane_route\(\) \{/lane_route() { return 0;/'
mutant "Lane 1 sperrt immer (nicht inert)" "1 9" forge-lanes.sh 's/if \[ "\$LANE" = 1 \] && ! lane_two_enabled; then   # Lane 1 ohne/if false; then   # Lane 1 ohne/'
mutant "M-1: Marker wird nie geloescht"  "10"  forge-lanes.sh 's/\[ -e "\$STATE\/lane1-armed" \] && rm -f "\$STATE\/lane1-armed"/:/'
mutant "M-1: Marker nur vor dem Lauf nicht geloescht (lane_lock_for)" "10" forge-lanes.sh '/ERST den Marker/{n;s/.*/    :/}'
mutant "M-1: Marker ohne Startzeit-Pruefung" "10" forge-lanes.sh 's/\[ "\$\(lane_starttime "\$pid"\)" = "\$st" \]/true/'
mutant "m-1: .lane-1 ohne eingang-2 akzeptiert" "1" forge-lanes.sh 's/^  if \[ "\$LANE" = 1 \] && ! lane_two_enabled; then printf .*return 0; fi$/  :/'
mutant "m-2: Lane-Variable im Executor"  "11"  forge-postbote.sh 's/^unset FORGE_LANE.*/export FORGE_LANE="$LANE"/'
mutant "m-2: Neustart nur fuer eine Lane" "5 11" forge-request-restart.sh 's/\[ -d "\$BASE\/post\/eingang-2" \]/false/'
echo "SUMMARY: $caught erkannt, $missed nicht erkannt"
[ "$missed" = 0 ]
