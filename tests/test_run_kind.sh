#!/usr/bin/env bash
# F5c Teil 2 S2c: RUN-Kind (Design §4.6) - ECHTER Watcher (--once) in einem Wegwerf-FORGE_BASE, echtes bin/forge-run-job, echte Jobs bzw. Probe-Jobs. Kein Netz, nie /srv/forge/post.
# Prueft: Grammatik (ABGELEHNT), Allowlist, Argument-Ablehnung (jede Regel einzeln), Exit-Mapping, kein Session-/Executor-Environment, Ergebnis nur ueber forge-write-result, ci-gate (Head-Bindung),
# Stubs (Exit 64), Einheiten-Verzeichnis, Zeitlimit mit Aufraeumen, G27 (Job-Verzeichnis == Allowlist, einziger Aufrufweg).
# Aufruf: tests/test_run_kind.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
T=$(mktemp -d); cleanup() { pkill -f "$T" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
export FORGE_BASE="$T/base"; POST="$FORGE_BASE/post"; WORK="$FORGE_BASE/work"
mkdir -p "$POST"/{eingang,ausgang,erledigt,log,state,control,graph,quarantaene} "$WORK" "$FORGE_BASE/home"
export FORGE_MIN_AGE=0 FORGE_POLL=1 HOME="$FORGE_BASE/home"
export FORGE_RUN_REPOS_FILE="$T/repos.list" FORGE_RUN_GATES_FILE="$T/gates.json"
export FORGE_MCP_TOKEN="SECRET-MCP-TOKEN-MUST-NOT-REACH-JOBS" OTEL_EXPORTER_OTLP_ENDPOINT="http://leak.invalid"
printf 'fixrepo\nforge-core\n' > "$FORGE_RUN_REPOS_FILE"
umask 0002
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# ---- git-Fixture: Repo mit Branch feat/x ----
R="$WORK/fixrepo"; mkdir -p "$R"
G() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G init -q -b main . && echo base > "$R/f.txt" && G add f.txt && G commit -q -m base
G checkout -q -b feat/x && echo more >> "$R/f.txt" && G commit -q -am more
HEAD=$(G rev-parse HEAD); G checkout -q main
# Gate-Tabelle: pass / fail / modify / slow / noisy
cat > "$FORGE_RUN_GATES_FILE" <<'EOF'
{"fixrepo": {
  "lint":   {"argv": ["bash", "-c", "echo lint ok"]},
  "format": {"argv": ["bash", "-c", "echo format broken; exit 1"]},
  "tests":  {"argv": ["bash", "-c", "test \"$(cat f.txt | wc -l)\" = 2 && echo two lines"]},
  "gitleaks": {"argv": ["bash", "-c", "echo x >> f.txt; echo modified the tracked tree"]},
  "diff_coverage": {"argv": ["bash", "-c", "sleep 30"], "timeout": 1},
  "shell_syntax": {"argv": ["bash", "-c", "head -c 3000000 /dev/zero | tr '\\0' y; echo; echo END"]}
}}
EOF

N=0
newname() { N=$((N+1)); NAME="RUN_forge-t$N.n-$(printf '%08x' $((0xa0000000 + N))).md"; NONCE=$(printf '%08x' $((0xa0000000 + N))); KEY="run:$N"; GID=7; mkdir -p "$POST/graph/$GID/$KEY"; U="$POST/graph/$GID/$KEY"; }
watch() { bash "$OPS/bin/forge-postbote.sh" --once >"$T/watcher.out" 2>&1; }
REPORT() { ls "$POST/ausgang/REPORT_${NAME%.md}_"*.md 2>/dev/null | head -1; }
hdr() { grep -m1 -E "^(- )?$1: " "$(REPORT)" | sed -E "s/^(- )?$1: //"; }
logf() { ls "$POST/log/"*"_${NAME%.md}.$1" 2>/dev/null | head -1; }
spec() { # job args-json [extra-json-fragment]   (graph_run_id/key/nonce aus der Umgebung)
  python3 - "$@" <<PY
import json, sys
o = {"job": sys.argv[1], "args": json.loads(sys.argv[2]), "graph_run_id": $GID, "key": "$KEY", "nonce": "$NONCE"}
if len(sys.argv) > 3: o.update(json.loads(sys.argv[3]))
print(json.dumps(o))
PY
}
submit() { newname; printf '%s' "$(spec "$@")" > "$POST/eingang/$NAME"; watch; }
CI_ARGS() { printf '{"repo":"fixrepo","branch":"feat/x","head":"%s","gates":%s}' "${1:-$HEAD}" "${2:-[\"lint\"]}"; }
rj() { python3 -c 'import json,sys
o=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): o=o[int(k)] if isinstance(o,list) else o[k]
print(json.dumps(o) if not isinstance(o,str) else o)' "$1" "$2"; }

# ================= 1. Grammatik =================
submit ci-gate "$(CI_ARGS)"
check "gueltiger RUN-Name wird ausgefuehrt (Report vorhanden)"   test -n "$(REPORT)"
check "Report: 'Executor: run'"                                  test "$(hdr Executor)" = "run"
check "Report: '- Modell: -'"                                    test "$(hdr Modell)" = "-"
check "Report: Nonce aus dem Namen"                              test "$(hdr Nonce)" = "$NONCE"
check "Report: Exit-Code 0"                                      test "$(hdr Exit-Code)" = "0"
check "Report: Fortsetzung nein, Session -"                      bash -c "[ \"$(hdr Fortsetzung)\" = nein ] && [ \"$(hdr Session)\" = - ]"
check "Brief archiviert (erledigt/), eingang/ leer"              bash -c "ls '$POST/erledigt/'*_'$NAME' && [ -z \"\$(ls '$POST/eingang')\" ]"
check "Run-Log log/<ts>_<base>.json existiert"                   test -n "$(logf json)"
check "kein state/<K>.session / .exec geschrieben"               bash -c "[ -z \"\$(ls -A '$POST/state' | grep -v '^\\.\\|heartbeat')\" ]"
check "result.json UND report.md in der Einheit"                 bash -c "[ -s '$U/result.json' ] && [ -s '$U/report.md' ]"
check "result.json: schema/job/nonce/key/graph_run_id"           bash -c "[ \"$(rj "$U/result.json" schema)\" = graph.run.v1 ] && [ \"$(rj "$U/result.json" job)\" = ci-gate ] && [ \"$(rj "$U/result.json" nonce)\" = $NONCE ] && [ \"$(rj "$U/result.json" key)\" = '$KEY' ] && [ \"$(rj "$U/result.json" graph_run_id)\" = $GID ]"
check "result.json: script_sha256 == sha256 des Job-Skripts"     test "$(rj "$U/result.json" script_sha256)" = "$(sha256sum "$OPS/bin/jobs/ci-gate" | cut -d' ' -f1)"
check "result.json: ok=true (alle Gates gruen)"                  test "$(rj "$U/result.json" ok)" = "true"
# M-100: Head im Ergebnis und in der Report-Kopfzeile stammen aus git
check "M-100: result.json head_sha == git Branch-Spitze"         test "$(rj "$U/result.json" head_sha)" = "$HEAD"
check "M-100: report.md beginnt mit 'Head: <sha>'"               test "$(head -n1 "$U/report.md")" = "Head: $HEAD"
check "stdout-Log ist JSON-Zeilen (type run-job.finished)"       bash -c "tail -n1 '$(logf json)' | python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); assert o[\"type\"]==\"run-job.finished\" and o[\"exit\"]==0'"
check "Report-Body nennt Job und Ausgabe-Ende"                   bash -c "grep -q 'RUN ci-gate' '$(REPORT)' && grep -q 'Output tail' '$(REPORT)'"

for variant in "RUN_forge-g1.fortsetzung.n-aaaaaaa1.md" "RUN_forge-g2.exec-codex.n-aaaaaaa2.md" "RUN_forge-g3.exec-claude.md" "RUN_forge-g4.aufwand-low.n-aaaaaaa4.md" "RUN_forge-g5.modell-gpt-6-luna.n-aaaaaaa5.md" \
               "RUN_forge-g6.fortsetzung.exec-codex.aufwand-high.modell-x.md"; do
  newname; NAME="$variant"; printf '%s' "$(spec ci-gate "$(CI_ARGS)")" > "$POST/eingang/$NAME"; watch
  check "ABGELEHNT: $variant"                                    bash -c "grep -q 'ABGELEHNT' '$(REPORT)' && ls '$POST/erledigt/'*_'$variant'"
  check "  nicht ausgefuehrt: kein Log, keine Ergebnisdatei"      bash -c "[ -z \"$(logf json)\" ] && [ -z \"\$(ls -A '$POST/graph/$GID/$KEY' 2>/dev/null | head -c1)\" ]"
done
rm -f "$POST"/ausgang/* "$POST"/log/*

# ================= 2. Allowlist und Argument-Ablehnung (jede Regel einzeln) =================
# Probe-Jobs: schreiben einen Marker, wenn sie laufen. Beweis, dass abgelehnte Auftraege NIE ausgefuehrt wurden.
PJ="$T/probe-jobs"; mkdir -p "$PJ"
for j in ci-gate merge lock-set deploy-check deploy-stage acceptance; do
  printf '#!/usr/bin/env bash\ntouch "%s/ran.%s"\nprintf "{\\"ok\\":true}" > "$FORGE_JOB_OUT/detail.json"\nexit 0\n' "$T" "$j" > "$PJ/$j"; chmod +x "$PJ/$j"
done
export FORGE_RUN_JOBS_DIR="$PJ"
rejectj() { # name job args-json [extra-json] fragment
  local n="$1" job="$2" args="$3" extra="$4" frag="$5"; N=$((N+1)); NAME="RUN_forge-t$N.n-$(printf '%08x' $((0xa0000000 + N))).md"; NONCE=$(printf '%08x' $((0xa0000000 + N))); KEY="run:$N"; GID=7
  mkdir -p "$POST/graph/$GID/$KEY"; U="$POST/graph/$GID/$KEY"; rm -f "$T"/ran.*
  printf '%s' "$(spec "$job" "$args" "$extra")" > "$POST/eingang/$NAME"; watch
  local e; e=$(cat "$(logf stderr)" 2>/dev/null)
  if [ "$(hdr Exit-Code)" = 65 ] && [ ! -e "$U/result.json" ] && ! ls "$T"/ran.* >/dev/null 2>&1 && [ "$(echo "$e" | wc -l)" = 1 ] && echo "$e" | grep -q -- "$frag"; then ok "abgelehnt (65): $n"
  else bad "abgelehnt (65): $n  [exit=$(hdr Exit-Code) ran=$(ls "$T"/ran.* 2>/dev/null) stderr=$e]"; fi
}
rawreject() { # name datei-inhalt-per-printf fragment
  local n="$1" content="$2" frag="$3"; N=$((N+1)); NAME="RUN_forge-t$N.n-$(printf '%08x' $((0xa0000000 + N))).md"; rm -f "$T"/ran.*
  printf "$content" > "$POST/eingang/$NAME"; watch
  local e; e=$(cat "$(logf stderr)" 2>/dev/null)
  if [ "$(hdr Exit-Code)" = 65 ] && ! ls "$T"/ran.* >/dev/null 2>&1 && [ "$(echo "$e" | wc -l)" = 1 ] && echo "$e" | grep -q -- "$frag"; then ok "abgelehnt (65): $n"
  else bad "abgelehnt (65): $n  [exit=$(hdr Exit-Code) ran=$(ls "$T"/ran.* 2>/dev/null) stderr=$e]"; fi
}
G1="$(CI_ARGS)"
# Job-Allowlist
rejectj "Job nicht in der Allowlist (rm)"              rm            "$G1" "{}" "Allowlist"
rejectj "Job mit Pfad ../merge"                        "../merge"    "$G1" "{}" "Allowlist"
rejectj "Job 'ci-gate/../merge'"                       "ci-gate/../merge" "$G1" "{}" "Allowlist"
rejectj "Job mit Leerzeichen 'ci-gate x'"              "ci-gate x"   "$G1" "{}" "Allowlist"
rejectj "Job leer"                                     ""            "$G1" "{}" "Allowlist"
rejectj "Job gross geschrieben 'CI-GATE'"              "CI-GATE"     "$G1" "{}" "Allowlist"
# Spec-Struktur / Typen
rejectj "unbekannter Top-Level-Schluessel"             ci-gate       "$G1" '{"extra":1}' "unbekannte Schluessel"
rejectj "lock_token bei Job ohne Lock"                 ci-gate       "$G1" '{"lock_token":"abcdefghijklmnop1234"}' "kein lock_token"
rejectj "job ist Zahl"                                 ci-gate       "$G1" '{"job":5}' "Typ"
rejectj "job ist Liste"                                ci-gate       "$G1" '{"job":["ci-gate"]}' "Typ"
rejectj "job ist Objekt"                               ci-gate       "$G1" '{"job":{}}' "Typ"
rejectj "args ist Liste"                               ci-gate       "$G1" '{"args":[]}' "Typ"
rejectj "args ist String"                              ci-gate       "$G1" '{"args":"x"}' "Typ"
rejectj "graph_run_id ist String"                      ci-gate       "$G1" '{"graph_run_id":"7"}' "Typ"
rejectj "graph_run_id ist bool"                        ci-gate       "$G1" '{"graph_run_id":true}' "Typ"
rejectj "graph_run_id ist Float"                       ci-gate       "$G1" '{"graph_run_id":7.5}' "Typ"
rejectj "graph_run_id 0"                               ci-gate       "$G1" '{"graph_run_id":0}' "Bereich"
rejectj "graph_run_id negativ"                         ci-gate       "$G1" '{"graph_run_id":-3}' "Bereich"
rejectj "key mit .."                                   ci-gate       "$G1" '{"key":"a/../b"}' "key"
rejectj "key mit Schraegstrich"                        ci-gate       "$G1" '{"key":"a/b"}' "key"
rejectj "key ist Liste"                                ci-gate       "$G1" '{"key":["x"]}' "Typ"
rejectj "nonce kein Hex"                               ci-gate       "$G1" '{"nonce":"zzzzzzzz"}' "nonce"
rejectj "nonce zu kurz"                                ci-gate       "$G1" '{"nonce":"abc"}' "nonce"
rejectj "nonce Grossbuchstaben"                        ci-gate       "$G1" '{"nonce":"ABCDEF12"}' "nonce"
rejectj "nonce ist Zahl"                               ci-gate       "$G1" '{"nonce":12345678}' "Typ"
# Argumente von ci-gate
rejectj "args: Schluessel fehlt (gates)"               ci-gate       "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"head\":\"$HEAD\"}" "{}" "erwartet genau"
rejectj "args: zusaetzlicher Schluessel"               ci-gate       "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"head\":\"$HEAD\",\"gates\":[\"lint\"],\"cmd\":\"id\"}" "{}" "erwartet genau"
rejectj "head zu kurz"                                 ci-gate       "$(CI_ARGS abc123)" "{}" "args.head"
rejectj "head Grossbuchstaben"                         ci-gate       "$(CI_ARGS "$(echo $HEAD | tr a-f A-F)")" "{}" "args.head"
rejectj "head mit Leerzeichen/Shell ';id'"             ci-gate       "$(CI_ARGS "${HEAD:0:30}; id")" "{}" "args.head"
rejectj "head ist Zahl"                                ci-gate       "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"head\":5,\"gates\":[\"lint\"]}" "{}" "args.head"
rejectj "head ist Liste"                               ci-gate       "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"head\":[1],\"gates\":[\"lint\"]}" "{}" "args.head"
for br in '../x' 'a..b' '-rf' '/abs' 'a b' 'a;id' 'a$(id)' 'a`id`' 'x.lock' 'x/' 'x//y' 'a/.hidden' 'Grossbuchstabe' '' ; do
  rejectj "branch '$br'" ci-gate "{\"repo\":\"fixrepo\",\"branch\":\"$br\",\"head\":\"$HEAD\",\"gates\":[\"lint\"]}" "{}" "args.branch"
done
rejectj "branch ist Objekt"                            ci-gate       "{\"repo\":\"fixrepo\",\"branch\":{},\"head\":\"$HEAD\",\"gates\":[\"lint\"]}" "{}" "args.branch"
rejectj "branch zu lang (82 Zeichen)"                  ci-gate       "{\"repo\":\"fixrepo\",\"branch\":\"$(printf 'a%.0s' $(seq 82))\",\"head\":\"$HEAD\",\"gates\":[\"lint\"]}" "{}" "args.branch"
for rp in '../fixrepo' 'fixrepo/../x' '/etc' 'unbekannt' 'fix repo' 'FIXREPO' '' ; do
  rejectj "repo '$rp'" ci-gate "{\"repo\":\"$rp\",\"branch\":\"feat/x\",\"head\":\"$HEAD\",\"gates\":[\"lint\"]}" "{}" "Repo"
done
rejectj "repo ist Liste"                               ci-gate       "{\"repo\":[\"fixrepo\"],\"branch\":\"feat/x\",\"head\":\"$HEAD\",\"gates\":[\"lint\"]}" "{}" "args.repo"
for gs in '[]' '["nope"]' '["lint","lint"]' '"lint"' '{"lint":1}' '[1]' '[["lint"]]' '[null]' '["lint","format","gitleaks","tests","diff_coverage","migration_class","shell_syntax","x"]'; do
  rejectj "gates $gs" ci-gate "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"head\":\"$HEAD\",\"gates\":$gs}" "{}" "args.gates"
done
# Argumente der uebrigen Jobs (Stubs validieren dieselbe Tabelle)
TOK='"lock_token":"abcdefghijklmnop1234"'
rejectj "merge ohne lock_token"                        merge         "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"main\"}" "{}" "lock_token"
rejectj "merge mit zu kurzem lock_token"               merge         "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"main\"}" '{"lock_token":"abc"}' "lock_token"
rejectj "merge lock_token mit Sonderzeichen"           merge         "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"main\"}" '{"lock_token":"abcdefghijklmnop;id"}' "lock_token"
rejectj "merge lock_token ist Liste"                   merge         "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"main\"}" '{"lock_token":["abcdefghijklmnop1234"]}' "Typ"
rejectj "merge base mit .."                            merge         "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"a..b\"}" "{\"lock_token\":\"abcdefghijklmnop1234\"}" "args.base"
rejectj "merge expected_head kurz"                     merge         "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"abc\",\"base\":\"main\"}" "{\"lock_token\":\"abcdefghijklmnop1234\"}" "args.expected_head"
rejectj "lock-set action unbekannt"                    lock-set      '{"repo":"fixrepo","action":"steal"}' "{\"lock_token\":\"abcdefghijklmnop1234\"}" "args.action"
rejectj "deploy-check deployment_id String"            deploy-check  '{"repo":"fixrepo","deployment_id":"1"}' "{}" "args.deployment_id"
rejectj "deploy-check deployment_id bool"              deploy-check  '{"repo":"fixrepo","deployment_id":true}' "{}" "args.deployment_id"
rejectj "deploy-check deployment_id 0"                 deploy-check  '{"repo":"fixrepo","deployment_id":0}' "{}" "args.deployment_id"
rejectj "deploy-check deployment_id 1.5"               deploy-check  '{"repo":"fixrepo","deployment_id":1.5}' "{}" "args.deployment_id"
rejectj "deploy-stage stage unbekannt"                 deploy-stage  '{"repo":"fixrepo","deployment_id":1,"stage":"yolo"}' "{\"lock_token\":\"abcdefghijklmnop1234\"}" "args.stage"
rejectj "acceptance deployment_id fehlt"               acceptance    '{"repo":"fixrepo"}' "{}" "erwartet genau"
# Rohe Dateien
rawreject "kein JSON"                                  'nope'                                         "JSON"
rawreject "leere Datei"                                ''                                             "JSON"
rawreject "JSON-Liste"                                 '[1,2]'                                        "Objekt"
rawreject "JSON-String"                                '"ci-gate"'                                    "Objekt"
rawreject "doppelter Schluessel"                       '{"job":"ci-gate","job":"merge"}'             "JSON"
rawreject "NaN"                                        '{"job":NaN}'                                  "JSON"
rawreject "Markdown statt JSON (LLM-Brief)"            '# Brief\n\nBitte tun.\n'                      "JSON"
rawreject "Binaer"                                     '\x00\x01\x02\xff'                             "JSON"
head -c 70000 /dev/zero | tr '\0' ' ' > "$T/big.json"; N=$((N+1)); NAME="RUN_forge-t$N.n-$(printf '%08x' $((0xa0000000 + N))).md"; cp "$T/big.json" "$POST/eingang/$NAME"; watch
check "Auftrag > 64 KB abgelehnt (65)"                  test "$(hdr Exit-Code)" = 65
check "  ... und nichts ausgefuehrt"                    bash -c "! ls '$T'/ran.* 2>/dev/null"

# ================= 3. Einheiten-Verzeichnis =================
unitcase() { # name  setup-cmd  fragment
  N=$((N+1)); NAME="RUN_forge-t$N.n-$(printf '%08x' $((0xa0000000 + N))).md"; NONCE=$(printf '%08x' $((0xa0000000 + N))); KEY="run:$N"; GID=7; U="$POST/graph/$GID/$KEY"; rm -f "$T"/ran.*; eval "$2"
  printf '%s' "$(spec ci-gate "$G1")" > "$POST/eingang/$NAME"; watch
  if [ "$(hdr Exit-Code)" = 66 ] && ! ls "$T"/ran.* >/dev/null 2>&1 && grep -q -- "$3" "$(logf stderr)"; then ok "$1"; else bad "$1 [exit=$(hdr Exit-Code) err=$(cat "$(logf stderr)")]"; fi
}
unitcase "Einheiten-Verzeichnis fehlt => 66, nichts ausgefuehrt"    ':'                                                         "fehlt"
unitcase "Einheiten-Verzeichnis ist Symlink => 66"                    'mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$U"'       "kein Verzeichnis"
check "  ... nichts ausserhalb geschrieben"                           test -z "$(ls -A "$T/elsewhere")"
unitcase "result.json existiert schon => 66 (nie ueberschreiben)"     'mkdir -p "$U"; echo "{}" > "$U/result.json"'              "schon vor"
check "  ... vorhandene Datei unberuehrt"                             test "$(cat "$U/result.json")" = "{}"
unitcase "report.md existiert schon => 66"                            'mkdir -p "$U"; echo "x" > "$U/report.md"'                 "schon vor"

# ================= 4. Exit-Mapping mit Probe-Jobs, Ergebnis nur ueber forge-write-result =================
probe() { # job exit-code detail-json   -> PJ/<job>
  printf '#!/usr/bin/env bash\ntouch "%s/ran.%s"\nprintf %%s %q > "$FORGE_JOB_OUT/detail.json"\necho "probe output line"\nexit %s\n' "$T" "$1" "$3" "$2" > "$PJ/$1"; chmod +x "$PJ/$1"
}
mapcase() { # name job exit detail expect-exit expect-ok
  probe "$2" "$3" "$4"; newname
  local args extra=""; case "$2" in ci-gate) args="$G1";; merge) args="{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"main\"}"; extra="{\"lock_token\":\"abcdefghijklmnop1234\"}";; esac
  printf '%s' "$(spec "$2" "$args" "${extra:-{\}}")" > "$POST/eingang/$NAME"; watch
  if [ "$(hdr Exit-Code)" = "$5" ] && [ "$(rj "$U/result.json" ok 2>/dev/null)" = "$6" ] && [ "$(rj "$U/result.json" detail.exit 2>/dev/null)" = "$3" ]; then ok "$1"; else bad "$1 [exit=$(hdr Exit-Code) ok=$(rj "$U/result.json" ok 2>&1) dexit=$(rj "$U/result.json" detail.exit 2>&1)]"; fi
}
mapcase "Job Exit 0 + ok:true => 0, ok=true"             ci-gate 0  '{"ok":true}'                       0 true
mapcase "Job Exit 0 + ok:false => 0 (Urteil im Ergebnis)"  ci-gate 0  '{"ok":false,"why":"red"}'         0 false
mapcase "Job Exit 0 ohne ok-Urteil => ok=false"           ci-gate 0  '{"x":1}'                           0 false
mapcase "Job Exit 3 (Vorbedingung) => 3, ok=false"        ci-gate 3  '{"ok":true}'                       3 false
mapcase "Job Exit 4 (needs_rebase) => 4, ok=false"        merge   4  '{"ok":false}'                      4 false
mapcase "Job Exit 64 => 64, ok=false"                     ci-gate 64 '{"ok":true}'                       64 false
mapcase "Job Exit 7 (sonstiger Fehler) => 7, ok=false"    ci-gate 7  '{"ok":true}'                       7 false
mapcase "Job Exit 255 => 255"                             ci-gate 255 '{"ok":true}'                      255 false
# Job liefert kaputtes detail.json => ok=false mit Fehlerhinweis, Ergebnis trotzdem gueltig
printf '#!/usr/bin/env bash\nprintf "{ kaputt" > "$FORGE_JOB_OUT/detail.json"\nexit 0\n' > "$PJ/ci-gate"; newname; printf '%s' "$(spec ci-gate "$G1")" > "$POST/eingang/$NAME"; watch
check "kaputtes detail.json => ok=false, error vermerkt"   bash -c "[ \"$(rj "$U/result.json" ok)\" = false ] && [ -n \"$(rj "$U/result.json" detail.error)\" ]"
# Job toetet sich per Signal
printf '#!/usr/bin/env bash\nkill -9 $$\n' > "$PJ/ci-gate"; newname; printf '%s' "$(spec ci-gate "$G1")" > "$POST/eingang/$NAME"; watch
check "Job per SIGKILL beendet => Exit 137, ok=false"      bash -c "[ \"$(hdr Exit-Code)\" = 137 ] && [ \"$(rj "$U/result.json" ok)\" = false ]"
# Job versucht result.json selbst zu schreiben: der Auftrag laeuft in einer frischen Arbeitsumgebung, die Einheit gehoert forge-write-result
printf '#!/usr/bin/env bash\nprintf "{\\"ok\\":true}" > "$FORGE_JOB_OUT/detail.json"\nexit 0\n' > "$PJ/ci-gate"
# ================= 5. Environment der Jobs: kein MCP-Token, kein OTEL, leeres Environment =================
cat > "$PJ/ci-gate" <<EOF
#!/usr/bin/env bash
env | sort > "$T/job-env.txt"
pwd > "$T/job-pwd.txt"
printf '{"ok":true}' > "\$FORGE_JOB_OUT/detail.json"
EOF
chmod +x "$PJ/ci-gate"; newname; printf '%s' "$(spec ci-gate "$G1")" > "$POST/eingang/$NAME"; watch
check "Job-Env: kein FORGE_MCP_TOKEN"                      bash -c "! grep -q 'MCP_TOKEN\|SECRET-MCP' '$T/job-env.txt'"
check "Job-Env: kein OTEL_*"                               bash -c "! grep -q 'OTEL' '$T/job-env.txt'"
check "Job-Env: kein CLAUDE/CODEX/ANTHROPIC/OPENAI"        bash -c "! grep -qi 'claude\|codex\|anthropic\|openai' '$T/job-env.txt'"
check "Job-Env: HOME zeigt in den Wegwerf-Bereich"         bash -c "grep -q '^HOME=.*forge-run-job' '$T/job-env.txt'"
check "Job-Env: FORGE_JOB_OUT gesetzt"                     bash -c "grep -q '^FORGE_JOB_OUT=' '$T/job-env.txt'"
check "Job-cwd ist der Wegwerf-Bereich"                    bash -c "grep -q forge-run-job '$T/job-pwd.txt'"
check "Wegwerf-Bereich nach dem Lauf entfernt"             bash -c "! ls -d /tmp/forge-run-job.* 2>/dev/null | xargs -r -I{} sh -c 'grep -q $T {}/job.out 2>/dev/null && echo leftover' | grep -q leftover"

# ================= 6. Zeitlimit: Watcher kuerzt, Job-Prozessgruppe wird aufgeraeumt =================
cat > "$PJ/ci-gate" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$T/slow.pid"
( sleep 300 ) &
echo \$! > "$T/slow.child.pid"
sleep 300
EOF
newname; printf '%s' "$(spec ci-gate "$G1")" > "$POST/eingang/$NAME"
FORGE_RUN_MAX_SECONDS=2 bash "$OPS/bin/forge-postbote.sh" --once >"$T/watcher.out" 2>&1
check "Zeitlimit: Exit-Code 124 im Report"                 test "$(hdr Exit-Code)" = 124
check "Zeitlimit: Hinweis im Report"                       grep -q 'Zeitlimit' "$(REPORT)"
sleep 1
# "lebt" = existiert und ist kein Zombie (in Containern ohne init bleibt ein verwaister, beendeter Prozess als Zombie stehen)
alive() { [ -r "/proc/$1/status" ] && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status"; }
check "Zeitlimit: Job-Prozess beendet"                     bash -c "$(declare -f alive); ! alive \$(cat '$T/slow.pid')"
check "Zeitlimit: Kindprozess des Jobs beendet"            bash -c "$(declare -f alive); ! alive \$(cat '$T/slow.child.pid')"
check "Zeitlimit: Brief trotzdem archiviert"               bash -c "ls '$POST/erledigt/'*_'$NAME'"

# ================= 7. Echte Jobs: ci-gate =================
unset FORGE_RUN_JOBS_DIR
cigate() { # gates-json [head]   -> Report/Ergebnis in U
  newname; printf '%s' "$(spec ci-gate "$(CI_ARGS "${2:-$HEAD}" "$1")")" > "$POST/eingang/$NAME"; watch; }
G checkout -q main
cigate '["lint","tests"]'
check "ci-gate gruen: Exit 0, ok=true, all_green"           bash -c "[ \"$(hdr Exit-Code)\" = 0 ] && [ \"$(rj "$U/result.json" ok)\" = true ] && [ \"$(rj "$U/result.json" detail.all_green)\" = true ]"
check "ci-gate: Gate-Status je Gate im Ergebnis"            bash -c "[ \"$(rj "$U/result.json" detail.gates.0.name)\" = lint ] && [ \"$(rj "$U/result.json" detail.gates.0.status)\" = pass ] && [ \"$(rj "$U/result.json" detail.gates.1.status)\" = pass ]"
check "ci-gate: Spitze am Anfang und Ende dokumentiert"     bash -c "[ \"$(rj "$U/result.json" detail.tip_at_start)\" = $HEAD ] && [ \"$(rj "$U/result.json" detail.tip_at_end)\" = $HEAD ]"
check "ci-gate: Quell-Repo unveraendert (kein Worktree, Branch main)" bash -c "[ -z \"\$(git -C '$R' worktree list | grep -v '$R ')\" ] && [ \"\$(git -C '$R' rev-parse --abbrev-ref HEAD)\" = main ] && [ -z \"\$(git -C '$R' status --porcelain)\" ]"
cigate '["lint","format"]'
check "ci-gate rot (format): Exit 0 aber ok=false"          bash -c "[ \"$(hdr Exit-Code)\" = 0 ] && [ \"$(rj "$U/result.json" ok)\" = false ] && [ \"$(rj "$U/result.json" detail.gates.1.status)\" = fail ]"
check "ci-gate rot: Ausgabe-Auszug nur im Report, nicht im Ergebnis" bash -c "grep -q 'format broken' '$U/report.md' && ! grep -q 'format broken' '$U/result.json'"
check "ci-gate rot: head_sha trotzdem aus git"              test "$(rj "$U/result.json" head_sha)" = "$HEAD"
cigate '["lint","diff_coverage","migration_class"]'
check "ci-gate: Gate ohne Eintrag => not_configured, NICHT gruen"  bash -c "[ \"$(rj "$U/result.json" ok)\" = false ] && [ \"$(rj "$U/result.json" detail.gates.2.status)\" = not_configured ]"
check "ci-gate: Gate-Zeitlimit => timeout"                  test "$(rj "$U/result.json" detail.gates.1.status)" = timeout
cigate '["gitleaks","lint"]'
check "ci-gate: Gate aendert getrackte Dateien => tree_modified (rot)" bash -c "[ \"$(rj "$U/result.json" detail.gates.0.status)\" = tree_modified ] && [ \"$(rj "$U/result.json" ok)\" = false ]"
check "  ... Checkout wurde zurueckgesetzt (naechstes Gate sieht den Head)" test "$(rj "$U/result.json" detail.gates.1.status)" = pass
check "  ... head_sha im Ergebnis weiterhin der Head"        test "$(rj "$U/result.json" head_sha)" = "$HEAD"
cigate '["shell_syntax"]'
check "ci-gate: 3 MB Ausgabe => Auszug begrenzt, Ergebnis < 256 KB"  bash -c "[ \$(stat -c %s '$U/result.json') -lt 262144 ] && [ \$(stat -c %s '$U/report.md') -lt 262144 ]"
# Vorbedingung: Head != Spitze  /  Branch fehlt
cigate '["lint"]' "$(printf 'a%.0s' $(seq 40))"
check "ci-gate: Head != Branch-Spitze => Exit 3"            test "$(hdr Exit-Code)" = 3
check "  ... ok=false, reason head_mismatch, tip genannt"   bash -c "[ \"$(rj "$U/result.json" ok)\" = false ] && [ \"$(rj "$U/result.json" detail.reason)\" = head_mismatch ] && [ \"$(rj "$U/result.json" detail.tip)\" = $HEAD ]"
check "  ... keine Gate wurde ausgefuehrt"                  test "$(rj "$U/result.json" detail.gates)" = "[]"
newname; printf '%s' "$(spec ci-gate "{\"repo\":\"fixrepo\",\"branch\":\"gibtsnicht\",\"head\":\"$HEAD\",\"gates\":[\"lint\"]}")" > "$POST/eingang/$NAME"; watch
check "ci-gate: Branch fehlt => Exit 3, reason branch_missing" bash -c "[ \"$(hdr Exit-Code)\" = 3 ] && [ \"$(rj "$U/result.json" detail.reason)\" = branch_missing ]"
# G28: Branch bewegt sich WAEHREND der Gates - das Ergebnis bleibt an den geprueften Head gebunden, die neue Spitze wird dokumentiert
cat > "$T/gates2.json" <<EOF
{"fixrepo": {"lint": {"argv": ["bash", "-c", "git -C $R -c user.name=t -c user.email=t@t checkout -q feat/x && echo y >> $R/g.txt && git -C $R add g.txt && git -C $R -c user.name=t -c user.email=t@t commit -q -m moved && git -C $R checkout -q main; echo moved"]}}}
EOF
FORGE_RUN_GATES_FILE="$T/gates2.json" cigate '["lint"]'
NEWTIP=$(G rev-parse feat/x)
check "G28: Branch bewegt sich waehrend der Gates => tip_at_end != Head, Ergebnis bleibt am Head" bash -c "[ \"$(rj "$U/result.json" detail.tip_at_start)\" = $HEAD ] && [ \"$(rj "$U/result.json" detail.tip_at_end)\" = $NEWTIP ] && [ \"$(rj "$U/result.json" head_sha)\" = $HEAD ]"
HEAD2=$NEWTIP

# ================= 8. Stubs: Exit 64, nichts ausgefuehrt =================
stubcase() { # job args extra
  newname; printf '%s' "$(spec "$1" "$2" "$3")" > "$POST/eingang/$NAME"; watch
  if [ "$(hdr Exit-Code)" = 64 ] && [ "$(rj "$U/result.json" ok)" = false ] && [ "$(rj "$U/result.json" detail.reason)" = not_implemented ] && grep -q 'not implemented' "$(REPORT)"; then ok "Stub $1 => Exit 64, ok=false, reason not_implemented"; else bad "Stub $1 [exit=$(hdr Exit-Code)]"; fi
}
stubcase merge        "{\"repo\":\"fixrepo\",\"branch\":\"feat/x\",\"expected_head\":\"$HEAD\",\"base\":\"main\"}" "{\"lock_token\":\"abcdefghijklmnop1234\"}"
stubcase lock-set     '{"repo":"fixrepo","action":"status"}'                                                        "{\"lock_token\":\"abcdefghijklmnop1234\"}"
stubcase deploy-check '{"repo":"fixrepo","deployment_id":3}'                                                        '{}'
stubcase deploy-stage '{"repo":"fixrepo","deployment_id":3,"stage":"verify"}'                                       "{\"lock_token\":\"abcdefghijklmnop1234\"}"
stubcase acceptance   '{"repo":"fixrepo","deployment_id":3}'                                                        '{}'
check "Stub-Skripte schreiben nichts ins Repo / Working tree" test -z "$(G status --porcelain)"

# ================= 9. G27: ein Weg =================
# Jede Datei in bin/jobs ist in der Allowlist und umgekehrt; der Watcher ruft Jobs ausschliesslich ueber forge-run-job.
JOBFILES=$(ls "$OPS/bin/jobs" | sort | tr '\n' ' ')
ALLOW=$(python3 -I - "$OPS/bin/forge-run-job" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
blk = src[src.index("JOBS = {"):src.index("TOP = ")]
print(" ".join(sorted(re.findall(r'^    "([a-z-]+)": \{"args"', blk, re.M))))
PY
)
check "G27: bin/jobs/* == Allowlist JOBS (${ALLOW})"        test "$(echo $JOBFILES)" = "$ALLOW"
check "G27: der Watcher startet Jobs nur ueber forge-run-job"  bash -c "! grep -n 'bin/jobs\|/jobs/' '$OPS/bin/forge-postbote.sh' | grep -v '^[0-9]*:#'"
check "G27: nur forge-run-job referenziert das Job-Verzeichnis" bash -c "[ \"\$(grep -l 'jobs' '$OPS'/bin/forge-* '$OPS'/bin/*.sh 2>/dev/null | grep -v forge-run-job | grep -v forge-postbote | wc -l)\" = 0 ]"
check "G27: forge-run-job hat keinen Auftrags-Schalter (kein --force/--skip/--trust/--no-)" bash -c "! grep -En -- '--(force|skip|trust|bypass|no-)' '$OPS/bin/forge-run-job'"
# Verhalten (behavioural half): jeder Job der Allowlist lehnt einen Auftrag mit ungueltigem Argument ab und fuehrt nichts aus
for j in ci-gate merge lock-set deploy-check deploy-stage acceptance; do
  rm -f "$T"/ran.*; printf '#!/usr/bin/env bash\ntouch "%s/ran.%s"\n' "$T" "$j" > "$PJ/$j"; chmod +x "$PJ/$j"
  FORGE_RUN_JOBS_DIR="$PJ" rejectj "G27 verhaltensseitig: $j mit Muellargumenten" "$j" '{"repo":"../x","zzz":1}' "{}" "erwartet genau"
done

# ================= 10. STOP haelt auch RUN-Auftraege zurueck =================
touch "$POST/control/STOP"; newname; printf '%s' "$(spec ci-gate "$G1")" > "$POST/eingang/$NAME"; watch
check "STOP: RUN-Auftrag bleibt in eingang/, nichts ausgefuehrt" bash -c "[ -e '$POST/eingang/$NAME' ] && [ -z \"$(logf json)\" ]"
rm -f "$POST/control/STOP"; watch
check "nach Freigabe wird der Auftrag ausgefuehrt"            test -n "$(REPORT)"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
