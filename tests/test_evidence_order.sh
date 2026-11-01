#!/usr/bin/env bash
# F5c Teil 2 S2c: test_evidence_order_watcher - pinnt Design W-3 am ECHTEN Watcher (Beweisspur): zu JEDEM Zeitpunkt ist mindestens eines von {Brief in eingang/, log/<ts>_<base>.json, erledigt/<ts>_<name>,
# ausgang/REPORT_<base>_*.md} vorhanden; es gibt keinen Moment, in dem ein angenommener Brief keine Spur hat. Reihenfolge: Log entsteht beim Start, der Brief wird VOR dem Report archiviert, der Report kommt zuletzt.
# Zwei Methoden: (1) deterministisch - ein vorgeschaltetes `mv` haelt VOR jedem Verschieben einen Schnappschuss des Postfachs fest (kein Sleep, keine Abtastung);
# (2) Abtastung mit einem schnellen Beobachter (Gegenprobe unter echter Nebenlaeufigkeit; Pruefreihenfolge eingang -> log -> archiv -> report ist lueckenlos, weil jede Spur entsteht, bevor die vorige verschwindet).
# Gleiche Pruefung fuer Claude-Stub, Codex-Stub, RUN-Auftrag, abgelehnten Namen (ABGELEHNT) und Fortsetzung ohne Session (Exit 2). Aufruf: tests/test_evidence_order.sh (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$HERE/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FORGE_BASE="$T/base"; POST="$FORGE_BASE/post"; mkdir -p "$POST"/{eingang,ausgang,erledigt,log,state,control,graph} "$FORGE_BASE/work" "$FORGE_BASE/home" "$T/fakebin" "$T/snaps"
export HOME="$FORGE_BASE/home" FORGE_MIN_AGE=0 FORGE_POLL=1 FORGE_RUN_REPOS_FILE="$T/repos.list" FORGE_RUN_GATES_FILE="$T/gates.json"
printf 'fixrepo\n' > "$FORGE_RUN_REPOS_FILE"; echo '{"fixrepo":{"lint":{"argv":["bash","-c","echo ok"]}}}' > "$FORGE_RUN_GATES_FILE"
umask 0002
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

R="$FORGE_BASE/work/fixrepo"; mkdir -p "$R"; G() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G init -q -b main . && echo a > "$R/f" && G add f && G commit -q -m a && G checkout -q -b feat/x && echo b >> "$R/f" && G commit -q -am b; HEAD=$(G rev-parse HEAD); G checkout -q main

# Schnappschuss-mv: VOR jedem mv, das eingang/ oder ausgang/ betrifft, das Postfach kopieren
cat > "$T/fakebin/mv" <<EOF
#!/usr/bin/env bash
case "\$*" in *eingang*|*ausgang*) n=\$(date +%s%N); mkdir -p "$T/snaps/\$n"; cp -a "$POST/eingang" "$POST/ausgang" "$POST/erledigt" "$POST/log" "$T/snaps/\$n/" 2>/dev/null; echo "\$*" > "$T/snaps/\$n/mvargs";; esac
exec /bin/mv "\$@"
EOF
chmod +x "$T/fakebin/mv"
# Stub-Executoren: Schnappschuss WAEHREND der Ausfuehrung
for ex in claude codex; do
cat > "$T/$ex" <<EOF
#!/usr/bin/env bash
cat >/dev/null
n=\$(date +%s%N); mkdir -p "$T/snaps/\$n"; cp -a "$POST/eingang" "$POST/ausgang" "$POST/erledigt" "$POST/log" "$T/snaps/\$n/" 2>/dev/null; echo "RUNNING" > "$T/snaps/\$n/mvargs"
sleep "\${STUB_SLEEP:-0}"
if [ "$ex" = codex ]; then
  printf '{"type":"thread.started","thread_id":"tid-1"}\n{"type":"item.completed","item":{"type":"agent_message","text":"PONG"}}\n{"type":"turn.completed","usage":{"input_tokens":1}}\n'
else
  printf '{"type":"result","subtype":"success","session_id":"sid-1","result":"PONG","total_cost_usd":0.01}\n'
fi
EOF
chmod +x "$T/$ex"; done
export CLAUDE_BIN="$T/claude" CODEX_BIN="$T/codex"
watch() { PATH="$T/fakebin:$PATH" bash "$OPS/bin/forge-postbote.sh" --once >"$T/watcher.out" 2>&1; }

# traces <name>: "E L A R" (eingang, log, archiv, report) eines Schnappschusses als 0/1
traces() { local d="$1" name="$2" base="${2%.md}" e=0 l=0 a=0 r=0
  [ -e "$d/eingang/$name" ] && e=1
  ls "$d/log/"*"_$base.json" >/dev/null 2>&1 && l=1
  ls "$d/erledigt/"*"_$name" >/dev/null 2>&1 && a=1
  ls "$d/ausgang/REPORT_${base}_"*.md >/dev/null 2>&1 && r=1
  echo "$e$l$a$r"; }

scenario() { # label name content expect-log(1|0)
  local label="$1" name="$2" content="$3" haslog="$4" during="${5:-$4}"
  rm -rf "$T/snaps"/*; rm -f "$POST"/eingang/* "$POST"/ausgang/* "$POST"/erledigt/* "$POST"/log/*
  printf '%s' "$content" > "$POST/eingang/$name"; watch
  local bad_n=0 seen_run=0 seen_arch=0 seen_rep=0 s tr
  for s in $(ls "$T/snaps" | sort -n); do
    tr=$(traces "$T/snaps/$s" "$name"); local args; args=$(cat "$T/snaps/$s/mvargs")
    [ "$tr" = 0000 ] && { bad_n=$((bad_n+1)); echo "   Schnappschuss ohne Spur: $args"; }
    case "$args" in
      RUNNING) seen_run=1; [ "$tr" = 1100 ] || { bad_n=$((bad_n+1)); echo "   waehrend der Ausfuehrung erwartet 1100 (eingang+log), war $tr"; };;
      *eingang*erledigt*|*erledigt*) :;;
    esac
    case "$args" in
      *"$POST/eingang/$name"*) seen_arch=1; want=$([ "$haslog" = 1 ] && echo 1100 || echo 1000); [ "$tr" = "$want" ] || { bad_n=$((bad_n+1)); echo "   vor dem Archivieren erwartet $want, war $tr"; };;
      *.teil*) seen_rep=1; want=$([ "$haslog" = 1 ] && echo 0110 || echo 0010); [ "$tr" = "$want" ] || { bad_n=$((bad_n+1)); echo "   vor dem Report erwartet $want (Archiv${haslog:+ + Log}), war $tr"; };;
    esac
  done
  [ "$bad_n" = 0 ] && ok "$label: in jedem Schnappschuss mindestens eine Spur, Reihenfolge Log -> Archiv -> Report" || bad "$label: $bad_n Verletzung(en)"
  [ "$seen_arch" = 1 ] && ok "$label: Schnappschuss vor dem Archivieren vorhanden" || bad "$label: kein Schnappschuss vor dem Archivieren"
  [ "$seen_rep" = 1 ] && ok "$label: Schnappschuss vor dem Report vorhanden" || bad "$label: kein Schnappschuss vor dem Report"
  [ "$during" = 1 ] && { [ "$seen_run" = 1 ] && ok "$label: Schnappschuss waehrend der Ausfuehrung (Brief bleibt in eingang/, Log existiert)" || bad "$label: kein Schnappschuss waehrend der Ausfuehrung"; }
  [ "$(traces "$POST" "$name")" = "$([ "$haslog" = 1 ] && echo 0111 || echo 0011)" ] && ok "$label: Endzustand Archiv + Report ($([ "$haslog" = 1 ] && echo mit || echo ohne) Log), eingang/ leer" || bad "$label: Endzustand $(traces "$POST" "$name")"
  ls "$POST/ausgang/" | grep -q '\.teil$' && bad "$label: .teil-Datei uebrig" || ok "$label: keine .teil-Reste"
}
scenario "claude"            "BRIEF_forge-e1.exec-claude.n-a1000001.md" "Bitte PONG." 1
scenario "codex"             "BRIEF_forge-e2.exec-codex.n-a1000002.md"  "Bitte PONG." 1
scenario "fortsetzung ohne Session (Exit 2, Log leer)" "BRIEF_forge-e3.fortsetzung.n-a1000003.md" "weiter" 1 0
scenario "ABGELEHNT (Name passt nicht, kein Log)" "BRIEF_forge-e4.aufwand-low.exec-claude.md" "x" 0
mkdir -p "$POST/graph/9/run:1"
runspec() { printf '{"job":"ci-gate","args":{"repo":"fixrepo","branch":"feat/x","head":"%s","gates":["lint"]},"graph_run_id":9,"key":"run:1","nonce":"%s"}' "$HEAD" "$1"; }
scenario "RUN-Auftrag (echter ci-gate)" "RUN_forge-e5.n-a1000005.md" "$(runspec a1000005)" 1 0
# RUN mit Probe-Job: Schnappschuss WAEHREND der Ausfuehrung (Auftrag bleibt in eingang/, Log existiert)
mkdir -p "$T/probe-jobs"
cat > "$T/probe-jobs/ci-gate" <<PROBE
#!/usr/bin/env bash
n=\$(date +%s%N); mkdir -p "$T/snaps/\$n"; cp -a "$POST/eingang" "$POST/ausgang" "$POST/erledigt" "$POST/log" "$T/snaps/\$n/" 2>/dev/null; echo "RUNNING" > "$T/snaps/\$n/mvargs"
printf '{"ok":true}' > "\$FORGE_JOB_OUT/detail.json"
PROBE
chmod +x "$T/probe-jobs/ci-gate"
rm -rf "$POST/graph/9/run:1"; mkdir -p "$POST/graph/9/run:1"
FORGE_RUN_JOBS_DIR="$T/probe-jobs" scenario "RUN-Auftrag (Probe-Job, waehrend der Ausfuehrung)" "RUN_forge-e5.n-a1000008.md" "$(runspec a1000008)" 1 1
rm -rf "$POST/graph/9/run:1"; mkdir -p "$POST/graph/9/run:1"
scenario "RUN abgelehnt (Auftrag ungueltig, Log vorhanden)" "RUN_forge-e6.n-a1000006.md" '{"job":"nope"}' 1 0
scenario "RUN abgelehnt (Name: .exec- ABGELEHNT, kein Log)" "RUN_forge-e7.exec-claude.n-a1000007.md" '{}' 0

# ---- (2) Abtastung unter Nebenlaeufigkeit ----
cat > "$T/sampler.py" <<'PY'
import glob, os, sys, time
post, names, done_flag = sys.argv[1], sys.argv[2].split(","), sys.argv[3]
viol, samples, start = [], 0, time.time()
live = {n: False for n in names}          # ab dem ersten Sichtkontakt zaehlt der Brief
while not os.path.exists(done_flag) and time.time() - start < 120:
    for n in names:
        base = n[:-3]
        e = os.path.exists(f"{post}/eingang/{n}")                          # Reihenfolge eingang -> log -> archiv -> report: lueckenlos
        l = e or bool(glob.glob(f"{post}/log/*_{base}.json"))
        a = l or bool(glob.glob(f"{post}/erledigt/*_{n}"))
        r = a or bool(glob.glob(f"{post}/ausgang/REPORT_{base}_*.md"))
        if r: live[n] = True
        elif live[n]: viol.append((round(time.time() - start, 4), n))
        samples += 1
print(samples, len(viol), viol[:5])
PY
rm -rf "$POST"/eingang/* "$POST"/ausgang/* "$POST"/erledigt/* "$POST"/log/*
names=""; for i in 1 2 3 4 5 6; do n="BRIEF_forge-s$i.exec-claude.n-b200000$i.md"; names="$names,$n"; done; names="${names#,}"
for n in ${names//,/ }; do printf 'x' > "$POST/eingang/$n"; done
python3 "$T/sampler.py" "$POST" "$names" "$T/done" > "$T/sampler.out" 2>&1 &
SP=$!
STUB_SLEEP=0.4 PATH="$T/fakebin:$PATH" bash "$OPS/bin/forge-postbote.sh" --once >"$T/watcher.out" 2>&1; touch "$T/done"; wait $SP
read -r samples nviol rest < "$T/sampler.out"
[ "${samples:-0}" -gt 1000 ] && ok "Abtastung: $samples Pruefungen unter Last" || bad "Abtastung: zu wenige Pruefungen ($samples)"
[ "${nviol:-1}" = 0 ] && ok "Abtastung: nie ein angenommener Brief ohne Spur" || bad "Abtastung: Verletzungen $nviol $rest"
[ "$(ls "$POST/ausgang" | grep -c '^REPORT_')" = 6 ] && ok "Abtastung: alle 6 Briefe haben einen Report" || bad "Abtastung: Reports fehlen"

# ---- Gegenprobe: der Test erkennt eine Reihenfolgeverletzung (Archivieren VOR dem Log-Anlegen waere ein Fehler) ----
# Ein Watcher, der den Brief VOR dem Start archiviert, hinterlaesst in dem Moment keine Spur ausser dem Archiv - das Archiv zaehlt; die gefaehrliche Variante ist "Log erst nach dem Archivieren
# UND Brief schon weg": simuliert mit einem Schnappschuss ohne alle Spuren.
mkdir -p "$T/empty/eingang" "$T/empty/log" "$T/empty/erledigt" "$T/empty/ausgang"
[ "$(traces "$T/empty" "BRIEF_forge-x.n-c0000001.md")" = 0000 ] && ok "Gegenprobe: ein Zustand ohne Spur wird als 0000 erkannt" || bad "Gegenprobe: traces()"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
