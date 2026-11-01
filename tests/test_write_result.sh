#!/usr/bin/env bash
# F5c Teil 2 S2b: bin/forge-write-result (atomares Schreiben der Ergebnisdatei, Pflichtschluessel, Nonce, Pfadsicherheit). Kein Netz, kein Watcher.
# Aufruf: tests/test_write_result.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$HERE/../bin/forge-write-result"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FORGE_GRAPH_DIR="$T/graph"; mkdir -p "$FORGE_GRAPH_DIR/42/build:1" "$FORGE_GRAPH_DIR/42/rev:1"
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
run() { python3 "$W" "$@" 2>"$T/err"; echo $? >"$T/rc"; }   # rc in Datei, Fehlertext in $T/err
rc() { cat "$T/rc"; }
good_build() { printf '{"schema":"graph.build.v1","nonce":"%s","graph_run_id":42,"key":"build:1","head_sha":"%s","branch":"forge/m1","files_changed":["a.py"],"self_check":"ok"}' "${1:-0a1b2c3d}" "$(printf 'a%.0s' $(seq 40))"; }

# --- gueltig: atomar geschrieben, Inhalt byte-identisch, keine .tmp-Reste ---
good_build > "$T/in.json"
run --nonce 0a1b2c3d 42/build:1 "$T/in.json" > "$T/out"
check "gueltig: Exit 0"                                   test "$(rc)" = 0
check "gueltig: result.json byte-identisch"                cmp -s "$T/in.json" "$FORGE_GRAPH_DIR/42/build:1/result.json"
check "gueltig: stdout 'ok <pfad> <sha256>'"               grep -Eq '^ok .*/result\.json [0-9a-f]{64}$' "$T/out"
check "gueltig: sha256 stimmt"                             bash -c "[ \"\$(awk '{print \$3}' '$T/out')\" = \"\$(sha256sum '$T/in.json' | cut -d' ' -f1)\" ]"
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
run;                                                                                                       reject "ohne Argumente"                   2 "Aufruf"
run --nonce 0a1b2c3d 42/build:1;                                                                           reject "zu wenig Argumente"               2 "Aufruf"
run --nonce XYZ 42/build:1 "$T/in.json";                                                                   reject "nonce kein Hex"                   2 "8 Hex"
for pk in "../x" "42/../build:1" "42/BUILD" "0/build:1" "42/" "/etc/passwd" "42/a/b"; do run --nonce 0a1b2c3d "$pk" "$T/in.json"; reject "Pfadangabe '$pk' abgelehnt" 2 "Pfadangabe"; done

# --- Verzeichnis: fehlt / Symlink ---
good_build > "$T/g.json"; sed 's/"key":"build:1"/"key":"build:9"/' "$T/g.json" > "$T/g9.json"
run --nonce 0a1b2c3d 42/build:9 "$T/g9.json";                                                              reject "Einheiten-Verzeichnis fehlt (legt der Graph an)" 3 "fehlt"
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$FORGE_GRAPH_DIR/42/build:9"
run --nonce 0a1b2c3d 42/build:9 "$T/g9.json";                                                              reject "Einheiten-Verzeichnis ist Symlink" 3 "kein Verzeichnis"
check "nichts ausserhalb geschrieben"                      test -z "$(ls -A "$T/elsewhere")"

# --- Rollen: jedes Schema nimmt sein Pflichtschluessel-Set ---
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":"PASS","reviewed_head":"%s","findings":[]}' "$(printf 'a%.0s' $(seq 40))" > "$T/r.json"
run --nonce 0a1b2c3d 42/rev:1 "$T/r.json";                                                                 check "review.v1 akzeptiert" test "$(rc)" = 0
printf '{"schema":"graph.review.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"rev:1","verdict":"PASS"}' > "$T/r.json"
run --nonce 0a1b2c3d 42/rev:1 "$T/r.json";                                                                 reject "review.v1 ohne findings" 3 "findings"
printf '{"schema":"graph.run.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","job":"ci-gate","ok":true,"detail":{"x":1}}' > "$T/o.json"
run --nonce 0a1b2c3d 42/build:1 "$T/o.json";                                                               check "run.v1 mit detail akzeptiert" test "$(rc)" = 0
printf '{"schema":"graph.judge.v1","nonce":"0a1b2c3d","graph_run_id":42,"key":"build:1","recommend":"ABANDON","rulings":[],"rationale":"x"}' > "$T/j.json"
run --nonce 0a1b2c3d 42/build:1 "$T/j.json";                                                               check "judge.v1 akzeptiert" test "$(rc)" = 0

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

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
