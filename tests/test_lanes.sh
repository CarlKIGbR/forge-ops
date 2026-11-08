#!/usr/bin/env bash
# Lane-Tests (ADR-040, zweite Postfach-Lane): Routing, Lane-flock, Repo-Sperren, globale GO-Sperre, Heartbeat-/Log-Trennung, Absturz einer Lane, Aktivierungs-Handshake, Lane 1 ohne Lane 2 inert.
# Echte Watcher-Prozesse (Lane 1 + Lane 2) mit Stub-claude im Wegwerf-Postfach. Aufruf: tests/test_lanes.sh   (Exit 0 = alles gruen)
# LANE_TEST_BIN=<bin-Verzeichnis> prueft eine andere Revision (z. B. master: die Lane-Tests muessen dort FEHLSCHLAGEN).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OPSBIN="${LANE_TEST_BIN:-$HERE/../bin}"
T=$(mktemp -d); trap 'cleanup_lanes; [ -n "${LANE_TEST_KEEP:-}" ] && echo "KEEP: $T" || rm -rf "$T"' EXIT
# shellcheck source=/dev/null
. "$HERE/lib_lanes.sh"
make_stub
SLOW="${LANE_TEST_SLEEP:-4}"
sec() { [ -z "${LANE_TEST_SECTIONS:-}" ] || [[ " $LANE_TEST_SECTIONS " == *" $1 "* ]]; }   # LANE_TEST_SECTIONS="3 6": nur diese Abschnitte

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 1; then
echo "# 1 Routing: Eingang entscheidet, Tag .lane-N bei Bedarf; Reports/Logs je Lane getrennt"
new_world w1; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2
brief 1 BRIEF_r1.md r1 1 "repos: none"
brief 2 BRIEF_r2.md r2 1 "repos: none"
wait_for 20 ended r1; wait_for 20 ended r2; sleep 2
check "Lane 1: Brief aus eingang/ laeuft mit FORGE_LANE=1"   grep -q ' START r1 1$' "$STUB_LOG"
check "Lane 2: Brief aus eingang-2/ laeuft mit FORGE_LANE=2" grep -q ' START r2 2$' "$STUB_LOG"
R1=$(ls "$POST"/ausgang/REPORT_BRIEF_r1_* 2>/dev/null | head -n1); R2=$(ls "$POST"/ausgang/REPORT_BRIEF_r2_* 2>/dev/null | head -n1)
check "Report Lane 2 traegt '- Lane: 2'"                     grep -q '^- Lane: 2$' "${R2:-/nonexistent}"
check "Report Lane 1 traegt KEINE Lane-Zeile (wie heute)"    bash -c "[ -f '${R1:-/nonexistent}' ] && ! grep -q '^- Lane:' '$R1'"
check "Archiv beider Briefe flach in erledigt/"              bash -c "ls '$POST'/erledigt/*_BRIEF_r1.md '$POST'/erledigt/*_BRIEF_r2.md"
check "Logzeile Lane 2 nur in postbote-lane2.log"            bash -c "grep -q ' BRIEF_r2.md ' '$(logf 2)' && ! grep -q ' BRIEF_r2.md ' '$(logf 1)'"
check "Logzeile Lane 1 nur in postbote.log"                  bash -c "grep -q ' BRIEF_r1.md ' '$(logf 1)' && ! grep -q ' BRIEF_r1.md ' '$(logf 2)'"
check "Roh-Log je Run flach in log/ (Importer-Glob)"         bash -c "ls '$POST'/log/*_BRIEF_r1.json '$POST'/log/*_BRIEF_r2.json"
brief 1 BRIEF_t2.lane-2.md t2 1 "repos: none"          # Tag .lane-2 im Eingang 1 => wandert nach eingang-2/
brief 2 BRIEF_t1.lane-1.md t1 1 "repos: none"          # Tag .lane-1 im Eingang 2 => wandert nach eingang/
wait_for 25 ended t2; wait_for 25 ended t1; sleep 1
check "Tag .lane-2 im Eingang 1: von Lane 2 ausgefuehrt"     grep -q ' START t2 2$' "$STUB_LOG"
check "Tag .lane-1 im Eingang 2: von Lane 1 ausgefuehrt"     grep -q ' START t1 1$' "$STUB_LOG"
check "ROUTED im Log der abgebenden Lane"                    bash -c "grep -q 'ROUTED BRIEF_t2.lane-2.md lane 1 -> lane 2' '$(logf 1)' && grep -q 'ROUTED BRIEF_t1.lane-1.md lane 2 -> lane 1' '$(logf 2)'"
check "getaggter Brief: Report-Kopf nennt den vollen Namen"  bash -c "grep -q '^- Brief: BRIEF_t2.lane-2.md$' '$POST'/ausgang/REPORT_BRIEF_t2.lane-2_*.md"
brief 1 BRIEF_t3.lane-3.md t3 1 "repos: none"
wait_for 15 bash -c "ls '$POST'/ausgang/REPORT_BRIEF_t3.lane-3_* "
check "unbekannter Tag .lane-3: ABGELEHNT, nichts gestartet" bash -c "grep -q 'ABGELEHNT' '$POST'/ausgang/REPORT_BRIEF_t3.lane-3_*.md && ! grep -q ' START t3 ' '$STUB_LOG'"
stop_lane 1; stop_lane 2

new_world w1b                                              # Lane 2 nicht aktiviert (kein eingang-2/): Tag bleibt wie heute ein Schemafehler
start_lane 1
brief 1 BRIEF_u1.lane-2.md u1 1 "repos: none"
wait_for 15 bash -c "ls '$POST'/ausgang/REPORT_BRIEF_u1.lane-2_*"
check "ohne eingang-2/: .lane-2 => ABGELEHNT wie bisher, Datei nicht verschoben" bash -c "grep -q ABGELEHNT '$POST'/ausgang/REPORT_BRIEF_u1.lane-2_*.md && [ ! -d '$POST/eingang-2' ]"
check "ohne Lane 2: keine locks/-Dateien, kein lane1-armed"  bash -c "[ ! -e '$POST/state/locks' ] && [ ! -e '$POST/state/lane1-armed' ]"
stop_lane 1
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 2; then
echo "# 2 Lane-flock: je Lane genau eine Instanz, beide Lanes nebeneinander"
new_world w2; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; sleep 2
check "Lane 1 und Lane 2 laufen gleichzeitig"                bash -c "kill -0 ${LANE_PID[1]} && kill -0 ${LANE_PID[2]}"
check "getrennte flock-Dateien .lock / .lock-lane2"          bash -c "[ -e '$POST/state/.lock' ] && [ -e '$POST/state/.lock-lane2' ]"
out2=$(FORGE_LANE=2 timeout 10 bash "$OPSBIN/forge-postbote.sh" 2>&1); rc2=$?
check "zweite Instanz Lane 2: Exit 1 'laeuft bereits'"       bash -c "[ $rc2 = 1 ] && grep -q 'laeuft bereits' <<<'$out2'"
out1=$(FORGE_LANE=1 timeout 10 bash "$OPSBIN/forge-postbote.sh" 2>&1); rc1=$?
check "zweite Instanz Lane 1: Exit 1 'laeuft bereits'"       bash -c "[ $rc1 = 1 ] && grep -q 'laeuft bereits' <<<'$out1'"
FORGE_LANE=7 bash "$OPSBIN/forge-postbote.sh" >/dev/null 2>&1; rc7=$?
check "FORGE_LANE=7: nicht unterstuetzt, Exit 2"             test "$rc7" = 2
stop_lane 1; stop_lane 2
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 3; then
echo "# 3 Repo-Sperre: gleiches Repo => nacheinander (zweiter wartet, geloggt); verschiedene Repos => parallel"
new_world w3; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_a1.md a1 "$SLOW" "repos: forge-core"
wait_for 15 started a1
brief 2 BRIEF_a2.md a2 1 "Repos: forge-core, forge-docs-unknown-ignored"   # unbekannter Name => ALLE => wartet auf a1 ebenfalls
wait_for 40 ended a2; sleep 1
check "gleiches Repo: Lauf B startet erst nach Ende von A"   after a1 a2
check "wartende Lane loggt LOCKWAIT waiting + acquired"      bash -c "grep -q 'LOCKWAIT lane=2 brief=BRIEF_a2.md' '$(logf 2)' && grep -q 'acquired after' '$(logf 2)'"
check "LOCKWAIT nennt den Halter (Lane 1, Brief)"            bash -c "grep -q 'held-by: lane=1 brief=BRIEF_a1.md\|held-by: .*BRIEF_a1.md' '$(logf 2)' || grep -q 'lock=all' '$(logf 2)'"

new_world w3b; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_b1.md b1 "$SLOW" "repos: forge-core"
wait_for 15 started b1
brief 2 BRIEF_b2.md b2 2 "repos: forge-ops"
wait_for 40 ended b2; wait_for 20 ended b1
check "verschiedene Repos: Laeufe ueberschneiden sich"       overlap b1 b2
check "kein LOCKWAIT bei verschiedenen Repos"                bash -c "! grep -q LOCKWAIT '$(logf 1)' '$(logf 2)'"
stop_lane 1; stop_lane 2

new_world w3c; mkdir -p "$POST/eingang-2"                    # Repo-Satz unbekannt (keine repos:-Zeile) => ALLE: serialisiert gegen jeden
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_c1.md c1 "$SLOW" "repos: forge-core"
wait_for 15 started c1
brief 2 BRIEF_c2.md c2 1                                      # keine Angabe
wait_for 40 ended c2
check "ohne repos:-Zeile: sperrt ALLES (wartet auf Lauf mit anderem Repo)" after c1 c2
brief 1 BRIEF_c3.md c3 "$SLOW" "repos: forge-core"
wait_for 15 started c3
brief 2 BRIEF_c4.md c4 1 "repos: none"
wait_for 20 ended c4; wait_for 20 ended c3
check "repos: none: kein Repo-Lock, laeuft parallel"          overlap c3 c4
brief 2 BRIEF_c5.md c5 "$SLOW" "repos: forge-core"
wait_for 15 started c5
brief 1 BRIEF_c6.md c6 1 "repos: nosuchrepo"                  # Name nicht in etc/lane-repos.list => ALLE
wait_for 40 ended c6
check "unbekannter Repo-Name => ALLE (wartet)"               after c5 c6
brief 1 BRIEF_c7.md c7 "$SLOW" "repos: forge-core"
wait_for 15 started c7
brief 2 BRIEF_c8.md c8 1 "repos: fundament, forge-core"       # ein gemeinsames Repo genuegt
wait_for 40 ended c8
check "ein gemeinsames Repo aus mehreren => seriell"          after c7 c8
brief 1 BRIEF_k1.md k1 "$SLOW" "repos: forge-core"
wait_for 15 started k1
brief 2 BRIEF_k1.fortsetzung.md k1b 1 "repos: fundament"      # gleiches Kuerzel K => seriell (state/<K>.session)
wait_for 40 ended k1b
check "gleiches Kuerzel K, anderes Repo => seriell (Session-Zustand)" after k1 k1b
stop_lane 1; stop_lane 2
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 4; then
echo "# 4 GO-Sperre: nie zwei GOs gleichzeitig (lane-uebergreifend); GO blockiert keine Nicht-GO-Laeufe anderer Repos"
new_world w4; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 GO_g1.md g1 "$SLOW" "repos: forge-core"
wait_for 15 started g1
brief 2 GO_g2.md g2 1 "repos: forge-ops"                      # anderes Repo, aber auch GO
brief 2 BRIEF_n1.md n1 1 "repos: forge-node"                  # Nicht-GO, anderes Repo => darf parallel (Lane 2 ist aber mit g2 beschaeftigt: nach g2)
wait_for 40 ended g2; wait_for 20 ended g1
check "zwei GOs (verschiedene Repos) nacheinander"            after g1 g2
check "LOCKWAIT lock=deploy im Log der wartenden Lane"        grep -q 'LOCKWAIT lane=2 brief=GO_g2.md lock=deploy' "$(logf 2)"
wait_for 30 ended n1
new_world w4b; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 GO_h1.md h1 "$SLOW" "repos: forge-core"
wait_for 15 started h1
brief 2 BRIEF_h2.md h2 1 "repos: forge-ops"
wait_for 30 ended h2; wait_for 20 ended h1
check "GO + Nicht-GO in anderem Repo: parallel"               overlap h1 h2
brief 1 GO_h3.md h3 "$SLOW" "repos: forge-core"
wait_for 15 started h3
brief 2 GO_h4.md h4 1                                          # GO ohne repos: => ALLE + deploy
wait_for 40 ended h4
check "GO ohne repos: => seriell"                              after h3 h4
stop_lane 1; stop_lane 2
# RUN: Sperrplan aus dem JSON-Auftrag (Bibliothek direkt)
plan() { ( BINDIR="$OPSBIN"; POST="$T/p/post"; STATE="$POST/state"; LOGD="$POST/log"; LOGF="$LOGD/x.log"; FORGE_LANE=1; export FORGE_LANE_REPOS_FILE="$T/repos.list"
           utcl() { :; }; . "$OPSBIN/forge-lanes.sh" 2>/dev/null || exit 9; lane_paths; mkdir -p "$EIN"; cp "$1" "$EIN/$2"; lane_plan "$2"; echo "${PLAN_LOCKS[*]}" ); }
mkdir -p "$T/p"
printf '{"args":{"base":"main","branch":"x","expected_head":"%040d","repo":"forge-core"},"graph_run_id":1,"job":"merge","key":"m:1","nonce":"aaaaaaaa"}' 0 > "$T/p/merge.json"
printf '{"args":{"branch":"x","gates":["tests"],"head":"%040d","repo":"forge-ops"},"graph_run_id":1,"job":"ci-gate","key":"t:1","nonce":"bbbbbbbb"}' 0 > "$T/p/ci.json"
printf 'not json' > "$T/p/bad.json"
check "RUN merge: S:all X:deploy X:repo-forge-core"           test "$(plan "$T/p/merge.json" RUN_pm.n-aaaaaaaa.md)" = "S:all X:deploy X:repo-forge-core"
check "RUN ci-gate: S:all X:repo-forge-ops (kein deploy)"     test "$(plan "$T/p/ci.json" RUN_pc.n-bbbbbbbb.md)" = "S:all X:repo-forge-ops"
check "RUN unlesbar: X:all + deploy (sicherer Standard)"       test "$(plan "$T/p/bad.json" RUN_pb.n-cccccccc.md)" = "X:all X:deploy"
printf 'repos: forge-ops, forge-core\n' > "$T/p/go.md"
test "$(plan "$T/p/go.md" GO_pg.md)" = "S:all X:deploy X:repo-forge-core X:repo-forge-ops X:k-pg" && ok "GO: Erwerbsreihenfolge all < deploy < repos (sortiert) < K" || bad "GO Erwerbsreihenfolge" "$(plan "$T/p/go.md" GO_pg.md)"
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 5; then
echo "# 5 Heartbeat, Logstrom, Neustart-Flag je Lane getrennt"
new_world w5; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"; sleep 2
check "zwei Heartbeat-Dateien (heartbeat / heartbeat-lane2)"  bash -c "[ -s '$POST/state/heartbeat' ] && [ -s '$POST/state/heartbeat-lane2' ]"
stop_lane 2; h1a=$(cat "$POST/state/heartbeat"); h2a=$(cat "$POST/state/heartbeat-lane2"); sleep 3
h1b=$(cat "$POST/state/heartbeat"); h2b=$(cat "$POST/state/heartbeat-lane2")
check "Lane 2 gestoppt: ihr Heartbeat steht, der von Lane 1 laeuft" bash -c "[ '$h2a' = '$h2b' ] && [ '$h1a' != '$h1b' ]"
start_lane 2; sleep 2
FORGE_LANE=2 bash "$OPSBIN/forge-request-restart.sh" "lane2 test" >/dev/null
check "forge-request-restart.sh mit FORGE_LANE=2: Flag restart-requested-lane2" bash -c "[ -e '$POST/state/restart-requested-lane2' ] && [ ! -e '$POST/state/restart-requested' ]"
wait_for 10 bash -c "! kill -0 ${LANE_PID[2]}"
check "Lane 2 beendet sich (Exit 0) und loggt RESTART in IHREM Log" bash -c "grep -q 'RESTART requested' '$(logf 2)' && ! grep -q RESTART '$(logf 1)'"
check "Lane 1 laeuft weiter"                                   kill -0 "${LANE_PID[1]}"
bash "$OPSBIN/forge-request-restart.sh" "lane1 test" >/dev/null
check "ohne FORGE_LANE: Flag restart-requested (unveraendert)" test -e "$POST/state/restart-requested"
wait_for 10 bash -c "! kill -0 ${LANE_PID[1]}"
check "Lane 1 beendet sich, RESTART in postbote.log"           grep -q 'RESTART requested' "$(logf 1)"
stop_lane 1

# Heartbeat waehrend eines laengeren Laufs UND waehrend des Wartens auf eine Sperre
new_world w5b; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_e1.md e1 6 "repos: forge-core"; wait_for 15 started e1
brief 2 BRIEF_e2.md e2 1 "repos: forge-core"; sleep 2; hw1=$(cat "$POST/state/heartbeat-lane2"); sleep 3; hw2=$(cat "$POST/state/heartbeat-lane2")
check "wartende Lane haelt ihren Heartbeat am Leben"           test "$hw1" != "$hw2"
wait_for 30 ended e2
stop_lane 1; stop_lane 2
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 6; then
echo "# 6 Absturz einer Lane blockiert die andere nicht"
new_world w6; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_x1.md x1 30 "repos: forge-core"; wait_for 15 started x1
brief 2 BRIEF_x2.md x2 1 "repos: forge-core"; sleep 3
check "Lane 2 wartet (Repo von Lane 1 belegt)"                 bash -c "! grep -q ' START x2 ' '$STUB_LOG'"
pkill -9 -P "${LANE_PID[1]}" 2>/dev/null; kill -9 "${LANE_PID[1]}" 2>/dev/null; pkill -9 -f "$T/claude" 2>/dev/null   # wie systemd bei KillMode=mixed + SIGKILL: Watcher UND Executor weg
wait_for 20 started x2
check "Lane 1 kill -9: Lane 2 bekommt die Sperre und laeuft"   started x2
wait_for 10 ended x2
brief 2 BRIEF_x3.md x3 1 "repos: forge-ops"; wait_for 15 ended x3
check "Lane 2 verarbeitet weiter"                              ended x3
LANE_PID[1]=""
rm -f "$POST/eingang/BRIEF_x1.md"     # der abgebrochene Brief bliebe in eingang/ und liefe nach dem Neustart erneut (heutiges Verhalten); hier nicht gewollt
start_lane 1; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_x4.md x4 8 "repos: forge-core"; wait_for 15 started x4
brief 2 BRIEF_x5.md x5 1 "repos: forge-ops"; wait_for 20 ended x5      # parallel, Lane 2 frei
pkill -9 -P "${LANE_PID[2]}" 2>/dev/null; kill -9 "${LANE_PID[2]}" 2>/dev/null; LANE_PID[2]=""
wait_for 20 ended x4
check "Lane 2 kill -9: Lane 1 beendet ihren Lauf regulaer"     ended x4
brief 1 BRIEF_x6.md x6 1 "repos: forge-core"; wait_for 15 ended x6
check "Lane 1 laeuft nach Absturz von Lane 2 weiter (x6)"      ended x6
start_lane 2; sleep 2
brief 1 BRIEF_x7.md x7 1 "repos: forge-core" 25                 # Executor hinterlaesst einen 25 s langen Nachkommen
wait_for 15 ended x7; brief 2 BRIEF_x8.md x8 1 "repos: forge-core"
wait_for 12 started x8
check "verwaister Nachkomme des Executors haelt keine Sperre (Lane 2 startet sofort nach Ende)" started x8
wait_for 10 ended x8
stop_lane 2; stop_lane 1
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 7; then
echo "# 7 Aktivierungs-Handshake: Lane 2 startet nichts, solange ein Lane-1-Lauf ohne Sperren laeuft"
new_world w7
start_lane 1                                                    # eingang-2/ existiert noch nicht => Lane 1 nimmt keine Sperren
brief 1 BRIEF_y1.md y1 6 "repos: forge-core"; wait_for 15 started y1
start_lane 2                                                    # legt eingang-2/ an (Aktivierung)
brief 2 BRIEF_y2.md y2 1 "repos: forge-ops"                     # anderes Repo, aber Lane 1 ist nicht "armed"
sleep 2
check "Lane 2 wartet, obwohl das Repo verschieden ist (Lane 1 nicht armed)" bash -c "! grep -q ' START y2 ' '$STUB_LOG' && grep -q 'PEER lane=2 waiting' '$(logf 2)'"
wait_for 30 ended y2
check "nach Ende des ungesperrten Laufs startet Lane 2"         after y1 y2
check "Lane 1 hat sich armed (lane1-armed = PID, Log)"          bash -c "kill -0 \$(cat '$POST/state/lane1-armed') && grep -q 'lane 1 armed' '$(logf 1)'"
brief 1 BRIEF_y3.md y3 "$SLOW" "repos: forge-core"; wait_for 15 started y3
brief 2 BRIEF_y4.md y4 1 "repos: forge-core"; wait_for 30 ended y4
check "ab jetzt greifen die Repo-Sperren lane-uebergreifend"    after y3 y4
stop_lane 1
brief 2 BRIEF_y5.md y5 1 "repos: forge-core"; wait_for 20 ended y5
check "Lane 1 gestoppt (kein Prozess): Lane 2 laeuft ohne zu warten" ended y5
stop_lane 2
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 8; then
echo "# 8 Warten ist begrenzt, geloggt, bricht bei SIGTERM ab und haelt das Dispatch-Lock nie"
new_world w8; mkdir -p "$POST/eingang-2"
export FORGE_LANE_LOCK_WAIT=3
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_z1.md z1 9 "repos: forge-core"; wait_for 15 started z1
brief 2 BRIEF_z2.md z2 1 "repos: forge-core"
wait_for 15 grep -q TIMEOUT "$(logf 2)"
check "Zeitgrenze: TIMEOUT geloggt, Brief bleibt in eingang-2/" bash -c "grep -q 'LOCKWAIT lane=2 brief=BRIEF_z2.md lock=all.*TIMEOUT\|LOCKWAIT lane=2 brief=BRIEF_z2.md lock=repo-forge-core.*TIMEOUT' '$(logf 2)' && [ -e '$POST/eingang-2/BRIEF_z2.md' ]"
FORGE_LOCK_TIMEOUT=2 bash "$OPSBIN/forge-stop" "test" >/dev/null 2>&1; rcs=$?
check "forge-stop gelingt waehrend Lane 2 wartet (Dispatch-Lock frei)" test "$rcs" = 0
rm -f "$POST/control/STOP"
unset FORGE_LANE_LOCK_WAIT
stop_lane 2
check "SIGTERM waehrend des Wartens: Lane 2 beendet sich, Brief bleibt" bash -c "[ -e '$POST/eingang-2/BRIEF_z2.md' ]"
wait_for 20 ended z1
stop_lane 1

new_world w8b; mkdir -p "$POST/eingang-2"                       # SIGTERM mitten im Warten (Wartezeit lang)
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
brief 1 BRIEF_s1.md s1 8 "repos: forge-core"; wait_for 15 started s1
brief 2 BRIEF_s2.md s2 1 "repos: forge-core"; sleep 3
kill -TERM "${LANE_PID[2]}"; wait_for 10 bash -c "! kill -0 ${LANE_PID[2]}"
check "SIGTERM beim Warten: Lane 2 endet, 'aborted (shutdown)' geloggt" bash -c "! kill -0 ${LANE_PID[2]} 2>/dev/null && grep -q 'aborted (shutdown)' '$(logf 2)'"
check "Brief unangetastet in eingang-2/, nie gestartet"        bash -c "[ -e '$POST/eingang-2/BRIEF_s2.md' ] && ! grep -q ' START s2 ' '$STUB_LOG'"
LANE_PID[2]=""; stop_lane 1
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 9; then
echo "# 9 STOP gilt fuer beide Lanes; Lane 1 ohne Lane 2 bleibt inert"
new_world w9; mkdir -p "$POST/eingang-2"
start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
bash "$OPSBIN/forge-stop" "test" >/dev/null 2>&1
brief 1 BRIEF_q1.md q1 1 "repos: none"; brief 2 BRIEF_q2.md q2 1 "repos: none"; sleep 4
check "STOP: keine Lane startet einen Brief"                   bash -c "! grep -q START '$STUB_LOG' && grep -q 'paused by STOP' '$(logf 1)' && grep -q 'paused by STOP' '$(logf 2)'"
bash "$OPSBIN/forge-release" >/dev/null 2>&1
wait_for 15 ended q1; wait_for 15 ended q2
check "nach Freigabe laufen beide (Lane 1)"                    ended q1
check "nach Freigabe laufen beide (Lane 2)"                    ended q2
stop_lane 1; stop_lane 2
new_world w9b; start_lane 1
brief 1 BRIEF_q3.md q3 1; wait_for 15 ended q3; stop_lane 1
check "Lane 1 ohne Lane 2: state/ enthaelt nur .lock heartbeat q3.session q3.exec" bash -c "[ \"\$(ls -A '$POST/state' | LC_ALL=C sort | tr '\n' ' ')\" = 'heartbeat q3.exec q3.session ' ] || [ \"\$(ls -A '$POST/state' | LC_ALL=C sort | tr '\n' ' ')\" = '.lock heartbeat q3.exec q3.session ' ]"
check "Lane 1 ohne Lane 2: keine Lane-Artefakte (log, Report)"  bash -c "[ ! -e '$POST/log/postbote-lane2.log' ] && ! grep -q '^- Lane' '$POST'/ausgang/REPORT_BRIEF_q3_*.md"
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------
if sec 10; then
echo "# 10 Re-Aktivierung nach Rollback: veralteter Marker state/lane1-armed darf Lane 2 nie starten lassen (Verify M-1)"
new_world w10; mkdir -p "$POST/eingang-2"
start_lane 1; wait_for 10 test -s "$POST/state/lane1-armed"
rmdir "$POST/eingang-2"                                          # Rollback OHNE den Marker zu loeschen
sleep 2
check "Lane 1 raeumt ihren Marker selbst weg, sobald eingang-2/ fehlt" test ! -e "$POST/state/lane1-armed"
brief 1 BRIEF_ra.md ra 8 "repos: forge-core"; wait_for 15 started ra     # sperrfreier Lauf (eingang-2/ fehlt)
mkdir -p "$POST/eingang-2"; start_lane 2                        # Re-Aktivierung mitten im sperrfreien Lauf
brief 2 BRIEF_rb.md rb 2 "repos: forge-core"
wait_for 40 ended rb; wait_for 20 ended ra
check "Re-Aktivierung: Lane 2 startet erst nach dem sperrfreien Lauf (kein Overlap, gleiches Repo)" after ra rb
check "Lane 2 loggt PEER waehrend des sperrfreien Laufs"         grep -q 'PEER lane=2 waiting' "$(logf 2)"
stop_lane 1; stop_lane 2
# Marker-Hygiene: ein Marker mit lebender PID, aber falscher Startzeit (PID-Wiederverwendung) zaehlt nicht
new_world w10b; mkdir -p "$POST/eingang-2"
( exec flock "$POST/state/.lock" sleep 40 ) & FAKE1=$!; PIDS+=("$FAKE1"); sleep 1
printf '%s 1\n' "$FAKE1" > "$POST/state/lane1-armed"            # lebende PID, Startzeit passt nicht
start_lane 2; brief 2 BRIEF_rc.md rc 1 "repos: none"; sleep 4
check "Marker mit falscher Startzeit: Lane 2 wartet (PEER)"     bash -c "! grep -q ' START rc ' '$STUB_LOG' && grep -q 'PEER lane=2 waiting' '$(logf 2)'"
printf '%s %s\n' "$FAKE1" "$(sed -e 's/^.*) //' /proc/$FAKE1/stat | awk '{print $20}')" > "$POST/state/lane1-armed"
wait_for 15 started rc
check "Marker mit passender PID+Startzeit: Lane 2 startet"      started rc
kill -9 "$FAKE1" 2>/dev/null; stop_lane 2
fi

echo; echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
