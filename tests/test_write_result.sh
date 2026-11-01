#!/usr/bin/env bash
# F5c Teil 2 S2b: bin/forge-write-result (atomares Schreiben der Ergebnisdatei, Pflichtschluessel, Nonce, Pfadsicherheit). Kein Netz, kein Watcher.
# Aufruf: tests/test_write_result.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$HERE/../bin/forge-write-result"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FORGE_GRAPH_DIR="$T/graph"; mkdir -p "$FORGE_GRAPH_DIR/42/build:1" "$FORGE_GRAPH_DIR/42/rev:1"
# M-100: git-Fixture - der Head kommt aus git, nie aus der JSON-Datei
WT="$T/wt"; mkdir -p "$WT"
G() { git -C "$WT" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G init -q -b forge/m1 . && echo one > "$WT/a.txt" && G add a.txt && G commit -q -m one
HEAD1=$(G rev-parse HEAD)
printf 'Ergebnis in Worten.\n' > "$T/rep.md"
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
# run: Aufruf wie ein Agent nach dem letzten Commit (Worktree + Report); runp: ohne beides (judge / Fehlerfaelle der Aufrufpruefung)
run() { local n="$1" nv="$2" pk="$3" f="$4"; shift 4; python3 "$W" "$n" "$nv" --worktree "$WT" --report "$T/rep.md" "$@" "$pk" "$f" 2>"$T/err"; echo $? >"$T/rc"; }   # rc in Datei, Fehlertext in $T/err
runp() { python3 "$W" "$@" 2>"$T/err"; echo $? >"$T/rc"; }
rc() { cat "$T/rc"; }
good_build() { printf '{"schema":"graph.build.v1","nonce":"%s","graph_run_id":42,"key":"build:1","files_changed":["a.py"],"self_check":"ok"}' "${1:-0a1b2c3d}"; }

# --- gueltig: atomar geschrieben, Inhalt byte-identisch, keine .tmp-Reste ---
good_build > "$T/in.json"
run --nonce 0a1b2c3d 42/build:1 "$T/in.json" > "$T/out"
check "gueltig: Exit 0"                                   test "$(rc)" = 0
check "gueltig: stdout 'ok <pfad> <sha256>' fuer result.json" grep -Eq '^ok .*/result\.json [0-9a-f]{64}$' "$T/out"
check "gueltig: sha256 stimmt mit der geschriebenen Datei"  bash -c "[ \"\$(awk '/result.json/ {print \$3}' '$T/out')\" = \"\$(sha256sum '$FORGE_GRAPH_DIR/42/build:1/result.json' | cut -d' ' -f1)\" ]"
check "gueltig: kein .tmp-Rest"                            bash -c "! ls -a '$FORGE_GRAPH_DIR/42/build:1' | grep -q tmp"
check "gueltig: Modus 0664"                                bash -c "[ \"\$(stat -c %a '$FORGE_GRAPH_DIR/42/build:1/result.json')\" = 664 ]"
good_build > "$T/in2.json"; sed -i 's/"self_check":"ok"/"self_check":"zweiter Lauf"/' "$T/in2.json"
run --nonce 0a1b2c3d 42/build:1 "$T/in2.json"
check "erneuter Aufruf ersetzt atomar (Agent korrigiert)"  grep -q 'zweiter Lauf' "$FORGE_GRAPH_DIR/42/build:1/result.json"

# --- Ablehnungen: Exit 3, genau eine Zeile, Zieldatei unveraendert ---
before=$(sha256sum "$FORGE_GRAPH_DIR/42/build:1/result.json")
reject() { # name rc-erwartet fragment
  local n="$1" want="$2" frag="$3"
  if [ "$(rc)" = "$want" ] && [ "$(wc -l < "$T/err")" = 1 ] && grep -q -- "$frag" "$T/err"; then ok "$n"; else bad "$n (rc=$(rc) err=$(cat "$T/err"))"; fi
}
good_build deadbeef > "$T/bad.json";                  run --nonce 0a1b2c3d 42/build:1 "$T/bad.json";     reject "falscher nonce in Datei"          3 "nonce"
good_build > "$T/bad.json"; run --nonce cafebabe 42/build:1 "$T/bad.json";                               reject "--nonce passt nicht zur Datei"    3 "nonce"
sed 's/"graph_run_id":42/"graph_run_id":43/' "$T/in.json" > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"; reject "falsche graph_run_id" 3 "graph_run_id"
sed 's/"key":"build:1"/"key":"build:2"/' "$T/in.json" > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"; reject "falscher key" 3 "key"
sed 's/"self_check":"ok"/"self_chek":"ok"/' "$T/in.json" > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"; reject "Tippfehler im Schluessel (fehlend/unbekannt)" 3 "Pflichtschluessel"
sed 's/"self_check":"ok"/"self_check":"ok","extra":1/' "$T/in.json" > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"; reject "unbekannter Schluessel" 3 "unbekannte Schluessel"
sed 's/graph.build.v1/graph.other.v1/' "$T/in.json" > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"; reject "unbekanntes Schema" 3 "schema"
printf '{ nope' > "$T/bad.json";                      run --nonce 0a1b2c3d 42/build:1 "$T/bad.json";     reject "kein JSON"                        3 "JSON"
printf '[1,2]' > "$T/bad.json";                       run --nonce 0a1b2c3d 42/build:1 "$T/bad.json";     reject "kein Objekt"                      3 "Objekt"
printf '{"a":1,"a":2}' > "$T/bad.json";               run --nonce 0a1b2c3d 42/build:1 "$T/bad.json";     reject "doppelter Schluessel"             3 "doppelter"
printf '{"a":NaN}' > "$T/bad.json";                   run --nonce 0a1b2c3d 42/build:1 "$T/bad.json";     reject "NaN"                              3 "NaN"
head -c 300000 /dev/zero | tr '\0' 'x' > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json";  reject "zu gross (>256 KB)"               3 "256 KB"
run --nonce 0a1b2c3d 42/build:1 "$T/missing.json";                                                       reject "JSON-Datei fehlt"                 3 "nicht lesbar"
mkfifo "$T/fifo"; run --nonce 0a1b2c3d 42/build:1 "$T/fifo";                                             reject "FIFO als Eingabe (kein Haengen)"  3 "regulaere"
check "Zieldatei nach allen Ablehnungen unveraendert"      bash -c "[ \"\$(sha256sum '$FORGE_GRAPH_DIR/42/build:1/result.json')\" = \"$before\" ]"

# --- Aufrufpruefung: Exit 2 ---
runp;                                                                                                       reject "ohne Argumente"                   2 "Aufruf"
runp --nonce 0a1b2c3d 42/build:1;                                                                           reject "zu wenig Argumente"               2 "Aufruf"
runp --nonce XYZ 42/build:1 "$T/in.json";                                                                   reject "nonce kein Hex"                   2 "8 Hex"
for pk in "../x" "42/../build:1" "42/BUILD" "0/build:1" "42/" "/etc/passwd" "42/a/b"; do runp --nonce 0a1b2c3d "$pk" "$T/in.json"; reject "Pfadangabe '$pk' abgelehnt" 2 "Pfadangabe"; done

# --- Verzeichnis: fehlt / Symlink ---
good_build > "$T/g.json"; sed 's/"key":"build:1"/"key":"build:9"/' "$T/g.json" > "$T/g9.json"
run --nonce 0a1b2c3d 42/build:9 "$T/g9.json";                                                              reject "Einheiten-Verzeichnis fehlt (legt der Graph an)" 3 "fehlt"
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$FORGE_GRAPH_DIR/42/build:9"
run --nonce 0a1b2c3d 42/build:9 "$T/g9.json";                                                              reject "Einheiten-Verzeichnis ist Symlink" 3 "kein Verzeichnis"
check "nichts ausserhalb geschrieben"                      test -z "$(ls -A "$T/elsewhere")"

# --- Rollen: jedes Schema nimmt sein Pflichtschluessel-Set ---
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":"PASS","findings":[]}' > "$T/r.json"
run --nonce 0a1b2c3d 42/rev:1 "$T/r.json";                                                                 check "review.v1 akzeptiert" test "$(rc)" = 0
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":"PASS"}' > "$T/r.json"
run --nonce 0a1b2c3d 42/rev:1 "$T/r.json";                                                                 reject "review.v1 ohne findings" 3 "findings"
printf '{"schema":"graph.run.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","job":"ci-gate","ok":true,"detail":{"x":1}}' > "$T/o.json"
run --nonce 0a1b2c3d 42/build:1 "$T/o.json";                                                               check "run.v1 mit detail akzeptiert" test "$(rc)" = 0
printf '{"schema":"graph.judge.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","recommend":"ABANDON","rulings":[],"rationale":"x"}' > "$T/j.json"
runp --nonce 0a1b2c3d 42/build:1 "$T/j.json";                                                               check "judge.v1 akzeptiert" test "$(rc)" = 0

# --- Typen: jeder falsche Typ eines Top-Level-Felds => Exit 3, eine Zeile, Zieldatei unveraendert (kein Traceback) ---
before=$(sha256sum "$FORGE_GRAPH_DIR/42/build:1/result.json")
for v in '[]' '{}' '1' 'true' 'null' '"x"'; do
  printf '{"schema":%s,"nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1"}' "$v" > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"
  if [ "$(rc)" = 3 ] && [ "$(wc -l < "$T/err")" = 1 ] && ! grep -q Traceback "$T/err"; then ok "schema=$v => Exit 3, eine Zeile"; else bad "schema=$v (rc=$(rc) err=$(cat "$T/err"))"; fi
done
fuzz_field() { # feld  gueltiger-Wert  falsche-Werte...
  local f="$1" good="$2"; shift 2
  for bv in "$@"; do
    python3 - "$T/in.json" "$T/bad.json" "$f" "$bv" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); o[sys.argv[3]] = json.loads(sys.argv[4]); json.dump(o, open(sys.argv[2], "w"))
PY
    run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"
    if [ "$(rc)" = 3 ] && [ "$(wc -l < "$T/err")" = 1 ] && ! grep -q Traceback "$T/err"; then ok "Typ $f=$bv abgelehnt"; else bad "Typ $f=$bv (rc=$(rc) err=$(cat "$T/err"))"; fi
  done
}
good_build > "$T/in.json"
for f in schema nonce key head_sha branch self_check notes; do fuzz_field $f x '[]' '{}' '1' 'true' 'null'; done
for f in graph_run_id; do fuzz_field $f x '[]' '{}' '"42"' 'true' 'null' '4.5'; done
for f in files_changed reserved_hits finding_responses; do fuzz_field $f x '{}' '"x"' '1' 'true' 'null'; done
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":[],"reviewed_head":{},"findings":{}}' > "$T/bad.json"; run --nonce 0a1b2c3d 42/rev:1 "$T/bad.json"
if [ "$(rc)" = 3 ] && [ "$(wc -l < "$T/err")" = 1 ]; then ok "review.v1 mit Fremdtypen abgelehnt"; else bad "review.v1 Fremdtypen (rc=$(rc))"; fi
printf '{"schema":"graph.run.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","job":"ci-gate","ok":"yes"}' > "$T/bad.json"; run --nonce 0a1b2c3d 42/build:1 "$T/bad.json"
if [ "$(rc)" = 3 ]; then ok "run.v1 ok als String abgelehnt"; else bad "run.v1 ok String (rc=$(rc))"; fi
check "Zieldatei nach den Typ-Ablehnungen unveraendert" bash -c "[ \"\$(sha256sum '$FORGE_GRAPH_DIR/42/build:1/result.json')\" = \"$before\" ]"

# ===================== M-100: Head-Herkunft (aus git, nie getippt) =====================
mkdir -p "$FORGE_GRAPH_DIR/42/m100:1" "$FORGE_GRAPH_DIR/42/m100:2" "$FORGE_GRAPH_DIR/42/m100:3"
U="$FORGE_GRAPH_DIR/42/m100:1"
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
mkb() { # key [feld=wert ...]: gueltiges build.v1 ohne Head/Branch, optional mit zusaetzlichen/ueberschriebenen Feldern (Wert ist JSON)
  local k="$1"; shift
  python3 - "$k" "$@" <<'PY' > "$T/m.json"
import json, sys
o = {"schema": "graph.build.v1", "nonce": "0a1b2c3d", "graph_run_id": 42, "key": sys.argv[1], "files_changed": ["a.py"], "self_check": "ok"}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("="); o[k] = json.loads(v)
print(json.dumps(o))
PY
}
mkb m100:1
run --nonce 0a1b2c3d 42/m100:1 "$T/m.json" > "$T/out"
check "M-100: Head fehlt in der Datei -> vom Werkzeug aus git eingetragen"  test "$(jget "$U/result.json" head_sha)" = "$HEAD1"
check "M-100: Branch fehlt -> aus git (symbolic-ref) eingetragen"           test "$(jget "$U/result.json" branch)" = "forge/m1"
check "M-100: report.md beginnt mit erzeugter Kopfzeile 'Head: <sha>'"      test "$(head -n1 "$U/report.md")" = "Head: $HEAD1"
check "M-100: Report-Text folgt unveraendert nach Leerzeile"                bash -c "[ \"\$(sed -n 2p '$U/report.md')\" = '' ] && [ \"\$(sed -n 3p '$U/report.md')\" = 'Ergebnis in Worten.' ]"
check "M-100: stdout meldet 'head <sha>'"                                    grep -qx "head $HEAD1" "$T/out"
# korrekt getippter Head ist unschaedlich (identisch), falscher wird abgelehnt - mit beiden Werten in der Meldung
mkb m100:2 head_sha="\"$HEAD1\"" branch='"forge/m1"'; run --nonce 0a1b2c3d 42/m100:2 "$T/m.json"
check "M-100: getippter, aber korrekter Head wird akzeptiert"                test "$(rc)" = 0
mkb m100:3 head_sha="\"$(printf 'b%.0s' $(seq 40))\""; run --nonce 0a1b2c3d 42/m100:3 "$T/m.json"; reject "M-100: falsch getippter Head -> Exit 3" 3 "weicht von git rev-parse HEAD"
check "M-100: Meldung nennt den git-Head"                                    grep -q "$HEAD1" "$T/err"
check "M-100: bei falschem Head nichts geschrieben"                          bash -c "[ -z \"\$(ls -A '$FORGE_GRAPH_DIR/42/m100:3')\" ]"
mkb m100:3 branch='"anderer/branch"'; run --nonce 0a1b2c3d 42/m100:3 "$T/m.json"; reject "M-100: falscher Branch -> Exit 3" 3 "Branch des Worktrees"
mkb m100:3; runp --nonce 0a1b2c3d 42/m100:3 "$T/m.json" --report "$T/rep.md"; reject "M-100: build ohne --worktree -> Exit 3 (Head nicht aus git)" 3 "worktree"
mkb m100:3; runp --nonce 0a1b2c3d --worktree "$WT" 42/m100:3 "$T/m.json"; reject "M-100: build ohne --report -> Exit 3 (Kopfzeile wird erzeugt)" 3 "report"
check "M-100: ohne Pflichtoptionen nichts geschrieben"                        bash -c "[ -z \"\$(ls -A '$FORGE_GRAPH_DIR/42/m100:3')\" ]"
# Report-Kopfzeile: selbst getippt - nur gleich zulaessig, sonst abgelehnt; die erzeugte ersetzt sie
printf 'Head: %s\nText nach getippter Kopfzeile.\n' "$HEAD1" > "$T/rep2.md"; mkb m100:3
python3 "$W" --nonce 0a1b2c3d --worktree "$WT" --report "$T/rep2.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"
check "M-100: getippte, korrekte Report-Zeile 'Head:' akzeptiert"             test "$(rc)" = 0
check "M-100: genau eine Head-Zeile im Report"                                test "$(grep -c '^Head:' "$FORGE_GRAPH_DIR/42/m100:3/report.md")" = 1
printf 'Head: %s\nText.\n' "$(printf 'c%.0s' $(seq 40))" > "$T/rep3.md"; mkb m100:3
python3 "$W" --nonce 0a1b2c3d --worktree "$WT" --report "$T/rep3.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: getippte falsche Report-Zeile 'Head:' -> Exit 3" 3 "Report-Zeile"
printf '' > "$T/rep4.md"; python3 "$W" --nonce 0a1b2c3d --worktree "$WT" --report "$T/rep4.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: leerer Report -> Exit 3" 3 "leer"
printf 'a\0b' > "$T/rep4.md"; python3 "$W" --nonce 0a1b2c3d --worktree "$WT" --report "$T/rep4.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: Report mit NUL -> Exit 3" 3 "NUL"
head -c 300000 /dev/zero | tr '\0' 'x' > "$T/rep4.md"; python3 "$W" --nonce 0a1b2c3d --worktree "$WT" --report "$T/rep4.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: Report > 256 KB -> Exit 3" 3 "KB"
# Zustand des Worktrees: ungecommittet / losgeloest / kein git / kein Verzeichnis
echo two >> "$WT/a.txt"; mkb m100:3; run --nonce 0a1b2c3d 42/m100:3 "$T/m.json"; reject "M-100: getrackte Aenderung ungecommittet -> Exit 3 ('erst committen')" 3 "committen"
G commit -q -am two; HEAD2=$(G rev-parse HEAD)
echo untracked > "$WT/neu.txt"; run --nonce 0a1b2c3d 42/m100:3 "$T/m.json"
check "M-100: nur UNGETRACKTE Dateien sind kein Hindernis"                    test "$(rc)" = 0
check "M-100: nach dem neuen Commit gilt der neue Head"                       test "$(jget "$FORGE_GRAPH_DIR/42/m100:3/result.json" head_sha)" = "$HEAD2"
G checkout -q --detach; mkb m100:3; run --nonce 0a1b2c3d 42/m100:3 "$T/m.json"; reject "M-100: losgeloester HEAD -> Exit 3 fuer build" 3 "detached"
# review / ops ohne Branch: losgeloest ist erlaubt, Head kommt aus git
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":"PASS","findings":[]}' > "$T/r.json"
run --nonce 0a1b2c3d 42/rev:1 "$T/r.json"
check "M-100: review.v1 mit losgeloestem HEAD akzeptiert"                      test "$(rc)" = 0
check "M-100: reviewed_head stammt aus git"                                     test "$(jget "$FORGE_GRAPH_DIR/42/rev:1/result.json" reviewed_head)" = "$HEAD2"
check "M-100: Review-Report beginnt mit 'Head: <sha>'"                          test "$(head -n1 "$FORGE_GRAPH_DIR/42/rev:1/report.md")" = "Head: $HEAD2"
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":"PASS","reviewed_head":"%s","findings":[]}' "$(printf 'a%.0s' $(seq 40))" > "$T/r.json"
run --nonce 0a1b2c3d 42/rev:1 "$T/r.json"; reject "M-100: getippter falscher reviewed_head -> Exit 3" 3 "weicht von git rev-parse HEAD"
G checkout -q forge/m1
run --nonce 0a1b2c3d 42/m100:3 "$T/m.json" --worktree "$T/gibt-es-nicht" 2>/dev/null
mkb m100:3; python3 "$W" --nonce 0a1b2c3d --worktree "$T/gibt-es-nicht" --report "$T/rep.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: --worktree fehlt -> Exit 3" 3 "worktree"
mkdir -p "$T/kein-git"; python3 "$W" --nonce 0a1b2c3d --worktree "$T/kein-git" --report "$T/rep.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: Verzeichnis ohne git -> Exit 3" 3 "worktree"
mkdir -p "$T/leer" && git -C "$T/leer" init -q; python3 "$W" --nonce 0a1b2c3d --worktree "$T/leer" --report "$T/rep.md" 42/m100:3 "$T/m.json" >/dev/null 2>"$T/err"; echo $? > "$T/rc"; reject "M-100: git ohne Commit -> Exit 3" 3 "Commit"
# judge hat kein Head-Feld; --worktree dort ist ein Aufruffehler
printf '{"schema":"graph.judge.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","recommend":"ABANDON","rulings":[],"rationale":"x"}' > "$T/j.json"
run --nonce 0a1b2c3d 42/build:1 "$T/j.json"; reject "M-100: judge.v1 mit --worktree -> Exit 3" 3 "kein Head-Feld"
# --report ohne Worktree (judge): Text unveraendert, KEINE Kopfzeile
runp --nonce 0a1b2c3d --report "$T/rep.md" 42/build:1 "$T/j.json"
check "M-100: judge --report ohne Worktree: Text unveraendert"                  cmp -s "$T/rep.md" "$FORGE_GRAPH_DIR/42/build:1/report.md"
# run.v1: Head optional, mit Worktree eingetragen
printf '{"schema":"graph.run.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","job":"ci-gate","ok":true}' > "$T/o.json"
run --nonce 0a1b2c3d 42/build:1 "$T/o.json"
check "M-100: run.v1 mit Worktree: head_sha aus git"                            test "$(jget "$FORGE_GRAPH_DIR/42/build:1/result.json" head_sha)" = "$(G rev-parse HEAD)"
runp --nonce 0a1b2c3d 42/build:1 "$T/o.json"
check "M-100: run.v1 ohne Worktree weiter moeglich (Job ohne Head)"             test "$(rc)" = 0
# --exclusive: vorhandene Dateien werden nie ersetzt, und es entsteht kein halber Zustand
mkdir -p "$FORGE_GRAPH_DIR/42/ex:1"; printf '{"schema":"graph.run.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"ex:1","job":"ci-gate","ok":true}' > "$T/x.json"
runp --nonce 0a1b2c3d --exclusive 42/ex:1 "$T/x.json"
check "M-100: --exclusive schreibt beim ersten Mal"                             test "$(rc)" = 0
sum1=$(sha256sum "$FORGE_GRAPH_DIR/42/ex:1/result.json")
sed -i 's/"ok":true/"ok":false/' "$T/x.json"; runp --nonce 0a1b2c3d --exclusive --report "$T/rep.md" 42/ex:1 "$T/x.json"; reject "M-100: --exclusive ersetzt nichts (Exit 3)" 3 "existiert bereits"
check "M-100: --exclusive: Ergebnisdatei unveraendert und kein report.md nachgeschoben" bash -c "[ \"\$(sha256sum '$FORGE_GRAPH_DIR/42/ex:1/result.json')\" = \"$sum1\" ] && [ ! -e '$FORGE_GRAPH_DIR/42/ex:1/report.md' ]"
# git-Konfiguration des Worktrees darf nichts ausfuehren (core.fsmonitor): der Marker darf nicht entstehen
G config core.fsmonitor "touch $T/PWNED; echo"; mkb m100:3; run --nonce 0a1b2c3d 42/m100:3 "$T/m.json"
check "M-100: core.fsmonitor des Worktrees wird nicht ausgefuehrt"              test ! -e "$T/PWNED"
G config --unset core.fsmonitor

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
