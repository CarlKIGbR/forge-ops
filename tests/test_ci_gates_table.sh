#!/usr/bin/env bash
# F5c Teil 2 S3a: Gate-Tabelle etc/ci-gates.json und die Gate-Skripte unter bin/gates/ - ECHTES bin/jobs/ci-gate gegen kleine synthetische Repos in einem Wegwerfverzeichnis.
# Prueft: Tabelle (gueltig, Gate-Namen in der Allowlist von forge-run-job, argv[0] aufloesbar, Hilfsskripte vorhanden/ausfuehrbar/bash -n, forge-core hat shell_syntax+tests, bewusst Unkonfiguriertes bleibt
# not_configured), shell_syntax (gruen/rot), gitleaks (echtes lokales Tool-Image, offline; sonst uebersprungen), tests-Gate mit gestubbtem docker (abgeleitete Namen, Aufraeumen bei Exit/SIGTERM/SIGKILL,
# Exit-Weitergabe, nichts ausserhalb der eigenen Namen). Kein Netz, nie /srv/forge/post, kein Produktions-Compose-Projekt (docker ist ein Stub; nur der gitleaks-Teil ruft das echte docker offline auf).
# Aufruf: tests/test_ci_gates_table.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$(cd "$HERE/.." && pwd -P)"
T=$(mktemp -d); cleanup() { [ -n "${KEEP:-}" ] && { echo "KEEP $T"; return; }; pkill -f "$T" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
unset FORGE_RUN_GATES_FILE FORGE_GATE_GITLEAKS_IMAGE                      # ci-gate soll die ausgelieferte Tabelle lesen
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
PASS=0; FAIL=0; SKIP=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
skip() { echo "SKIP  $1"; SKIP=$((SKIP+1)); }
TABLE="$OPS/etc/ci-gates.json"
GATEPATH="/usr/local/bin:/usr/bin:/bin"                                   # PATH, den ci-gate den Gates gibt

# ================= 1. Tabelle =================
tab() { python3 -I - "$TABLE" "$OPS" "$@" <<'PY'
import ast, json, os, re, shutil, subprocess, sys
table = json.load(open(sys.argv[1])); ops = sys.argv[2]; what = sys.argv[3]
src = open(os.path.join(ops, "bin", "forge-run-job"), encoding="utf-8").read()
names = ast.literal_eval(re.search(r"^GATE_NAMES = (\(.*\))$", src, re.M).group(1))
job_timeout = int(re.search(r'"ci-gate": \{[^\n]*"timeout": (\d+)\}', src).group(1))
gates = {r: g for r, g in table.items() if not r.startswith("_")}
def argvs():
    for r, g in gates.items():
        for n, s in g.items():
            yield r, n, s
if what == "names":                  # jedes Gate ist ein erlaubter Name
    sys.exit(0 if all(n in names for _, n, _ in argvs()) else 1)
if what == "shape":                  # argv = Liste von Strings, timeout = int 1..3600
    sys.exit(0 if all(isinstance(s.get("argv"), list) and s["argv"] and all(isinstance(a, str) for a in s["argv"]) and type(s.get("timeout")) is int and 1 <= s["timeout"] <= 3600 for _, _, s in argvs()) else 1)
if what == "argv0":                  # argv[0] loest sich im Gate-PATH auf
    sys.exit(0 if all(shutil.which(s["argv"][0], path="/usr/local/bin:/usr/bin:/bin") for _, _, s in argvs()) else 1)
if what == "helpers":                # jeder "{ops}/..."-Pfad existiert, ist ausfuehrbar und bash -n sauber; Skripte liegen unter bin/gates/
    seen = 0
    for _, _, s in argvs():
        for a in s["argv"]:
            if "{ops}" in a:
                p = a.replace("{ops}", ops); seen += 1
                if not (p.startswith(os.path.join(ops, "bin", "gates") + os.sep) and os.path.isfile(p) and os.access(p, os.X_OK)): sys.exit(1)
                if subprocess.run(["bash", "-n", p]).returncode: sys.exit(1)
    sys.exit(0 if seen >= 3 else 1)
if what == "core":                   # forge-core: shell_syntax + tests + gitleaks; bewusst nicht konfiguriert: lint, format, diff_coverage, migration_class
    c = gates.get("forge-core", {})
    sys.exit(0 if {"shell_syntax", "tests", "gitleaks"} <= set(c) and not ({"lint", "format", "diff_coverage", "migration_class"} & set(c)) else 1)
if what == "norepo":                 # kein '*'-Eintrag, kein Eintrag fuer andere Repos als forge-ops/forge-core
    sys.exit(0 if set(gates) == {"forge-ops", "forge-core"} else 1)
if what == "budget":                 # Summe der Zeitlimits je Repo passt ins Job-Limit von ci-gate (3600 s); das tests-Gate hat >= 1200 s (Build + ~6 min Suite)
    sys.exit(0 if all(sum(s["timeout"] for s in g.values()) <= job_timeout for g in gates.values()) and gates["forge-core"]["tests"]["timeout"] >= 1200 else 1)
if what == "ops_subst":              # ci-gate ersetzt {ops}
    sys.exit(0 if "{ops}" in open(os.path.join(ops, "bin", "jobs", "ci-gate")).read() else 1)
sys.exit(2)
PY
}
check "Tabelle ist gueltiges JSON"                                    python3 -I -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])), dict)' "$TABLE"
check "Gate-Namen der Tabelle sind in der Allowlist von forge-run-job" tab names
check "argv/timeout jedes Eintrags wohlgeformt (Liste von Strings, int 1..3600)" tab shape
check "argv[0] jedes Eintrags loest sich im Gate-PATH auf"            tab argv0
check "Hilfsskripte: unter bin/gates/, ausfuehrbar, bash -n sauber"   tab helpers
check "forge-core: shell_syntax+tests+gitleaks; lint/format/diff_coverage/migration_class NICHT konfiguriert" tab core
check "nur forge-ops und forge-core haben Eintraege (kein '*', kein forge-docs)" tab norepo
check "Zeitlimits: Summe je Repo <= Job-Limit 3600 s, tests-Gate >= 1200 s" tab budget
check "ci-gate ersetzt {ops} in argv"                                 tab ops_subst
check "bin/gates/* und etc/gitleaks.toml vorhanden"                   bash -c "[ -x '$OPS/bin/gates/shell-syntax' ] && [ -x '$OPS/bin/gates/gitleaks' ] && [ -x '$OPS/bin/gates/forge-core-tests' ] && [ -s '$OPS/etc/gitleaks.toml' ]"
check "forge-ops-shell_syntax deckt bin/gates/* ab"                   grep -q 'bin/gates/\*' "$TABLE"

# ================= Hilfen: synthetische Repos, ci-gate-Aufruf =================
mkdir -p "$T/work"
mkrepo() { # name  -> $T/work/<name> mit Branch feat/x (Head in $HEADX)
  R="$T/work/$1"; rm -rf "$R"; mkdir -p "$R"
  git -C "$R" init -q -b main . 2>/dev/null
  git -C "$R" config user.name t; git -C "$R" config user.email t@t; git -C "$R" config commit.gpgsign false
  mkdir -p "$R/scripts"
  printf '#!/usr/bin/env bash\nset -u\necho ok\n' > "$R/scripts/good.sh"
  printf '#!/usr/bin/env python3\nprint("not shell (( \\n")\n' > "$R/scripts/tool.py"
  printf 'x = 1\n' > "$R/notes.txt"
  printf 'services:\n  tests: {}\n' > "$R/compose.yaml"; printf 'FROM scratch AS test\n' > "$R/Dockerfile"
  printf '# Pins\nIMG_PYTHON=python@sha256:%064d\nIMG_PGVECTOR=pgvector/pgvector@sha256:%064d\nIMG_FORGE_CORE_APP=sha256:%064d\n' 1 2 3 > "$R/images.lock"
  git -C "$R" add -A; git -C "$R" commit -q -m base
  git -C "$R" checkout -q -b feat/x; echo more >> "$R/notes.txt"; git -C "$R" commit -q -am more
  HEADX=$(git -C "$R" rev-parse HEAD); git -C "$R" checkout -q main
}
N=0
cig() { # repo-name gates [gates-file]  -> D = detail.json, RC = Exit von ci-gate, SCR = Wegwerfbereich
  N=$((N+1)); SCR="$T/run$N"; mkdir -p "$SCR/out"
  FORGE_JOB_OUT="$SCR/out" FORGE_RUN_GATES_FILE="${3:-}" python3 "$OPS/bin/jobs/ci-gate" "$T/work/$1" feat/x "$(git -C "$T/work/$1" rev-parse refs/heads/feat/x)" "$2" >"$SCR/stdout" 2>&1; RC=$?; D="$SCR/out/detail.json"
}
cig_shipped() { N=$((N+1)); SCR="$T/run$N"; mkdir -p "$SCR/out"; env -u FORGE_RUN_GATES_FILE FORGE_JOB_OUT="$SCR/out" python3 "$OPS/bin/jobs/ci-gate" "$T/work/$1" feat/x "$(git -C "$T/work/$1" rev-parse refs/heads/feat/x)" "$2" >"$SCR/stdout" 2>&1; RC=$?; D="$SCR/out/detail.json"; }
dj() { python3 -I -c 'import json,sys
o=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): o=o[int(k)] if isinstance(o,list) else o[k]
print(json.dumps(o) if not isinstance(o,str) else o)' "$D" "$1"; }
gst() { python3 -I -c 'import json,sys
o=json.load(open(sys.argv[1]))
print(next((g["status"] for g in o["gates"] if g["name"]==sys.argv[2]), "?"))' "$D" "$1"; }

# ================= 2. ausgelieferte Tabelle: shell_syntax / nicht konfiguriert =================
mkrepo forge-core
cig_shipped forge-core 'shell_syntax'
check "forge-core shell_syntax gruen (Exit 0, ok, pass)"              bash -c "[ $RC = 0 ] && [ \"$(dj ok)\" = true ] && [ \"$(gst shell_syntax)\" = pass ]"
check "  ... Ausgabe: Skripte gefunden (nicht leer gelaufen)"          bash -c "grep -q '1 Skripte geprueft, 0 fehlerhaft' '$SCR/gatelogs/shell_syntax.log'"
check "  ... Checkout geklont, HEAD == Head (gebunden)"               test "$(git -C "$SCR/checkout" rev-parse HEAD 2>/dev/null)" = "$HEADX"
# kaputtes Skript mit Endung .sh => rot; kaputtes Skript OHNE Endung mit bash-Shebang => rot; .py wird nie als Shell geprueft
printf '#!/usr/bin/env bash\nif true; then\n  echo x\n' > "$T/work/forge-core/scripts/broken.sh"
git -C "$T/work/forge-core" checkout -q feat/x; git -C "$T/work/forge-core" add -A; git -C "$T/work/forge-core" commit -q -m broken; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
cig_shipped forge-core 'shell_syntax'
check "forge-core shell_syntax ROT bei kaputtem .sh (fail, ok=false)" bash -c "[ \"$(gst shell_syntax)\" = fail ] && [ \"$(dj ok)\" = false ]"
check "  ... Ausgabe nennt die kaputte Datei"                         bash -c "grep -q 'scripts/broken.sh' '$SCR/gatelogs/shell_syntax.log' && ! grep -q 'tool.py' '$SCR/gatelogs/shell_syntax.log'"
git -C "$T/work/forge-core" checkout -q feat/x; git -C "$T/work/forge-core" rm -q scripts/broken.sh
printf '#!/bin/bash\nfor x in 1 2; do\n  echo $x\n' > "$T/work/forge-core/scripts/runme"; chmod +x "$T/work/forge-core/scripts/runme"
git -C "$T/work/forge-core" add -A; git -C "$T/work/forge-core" commit -q -m noext; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
cig_shipped forge-core 'shell_syntax'
check "forge-core shell_syntax ROT bei kaputtem Skript ohne Endung (Shebang)" test "$(gst shell_syntax)" = fail
git -C "$T/work/forge-core" checkout -q feat/x; git -C "$T/work/forge-core" rm -q -f scripts/runme; git -C "$T/work/forge-core" commit -q -m clean; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
cig_shipped forge-core 'shell_syntax'
check "  ... nach Entfernen wieder gruen"                             test "$(gst shell_syntax)" = pass
# ein Repo ganz ohne Shell-Skripte: --min 1 => rot (leer gelaufen ist nicht gruen)
mkrepo forge-core-empty; git -C "$T/work/forge-core-empty" checkout -q feat/x; git -C "$T/work/forge-core-empty" rm -q -r -f scripts; git -C "$T/work/forge-core-empty" commit -q -m none; HEADX=$(git -C "$T/work/forge-core-empty" rev-parse HEAD); git -C "$T/work/forge-core-empty" checkout -q main
( cd "$T/work/forge-core-empty" && git checkout -q feat/x && bash "$OPS/bin/gates/shell-syntax" --min 1 ) >/dev/null 2>&1; r1=$?
( cd "$T/work/forge-core-empty" && bash "$OPS/bin/gates/shell-syntax" ) >/dev/null 2>&1; r2=$?
check "shell-syntax --min 1 ohne Skripte => Exit 1, ohne --min => Exit 0" test "$r1$r2" = "10"
git -C "$T/work/forge-core-empty" checkout -q main
# bewusst Unkonfiguriertes und fremde Repos: not_configured => rot
mkrepo forge-docs
cig_shipped forge-core 'lint,format,diff_coverage,migration_class'
check "forge-core: lint/format/diff_coverage/migration_class => not_configured, ok=false" bash -c "[ \"$(gst lint)\" = not_configured ] && [ \"$(gst format)\" = not_configured ] && [ \"$(gst diff_coverage)\" = not_configured ] && [ \"$(gst migration_class)\" = not_configured ] && [ \"$(dj ok)\" = false ]"
cig_shipped forge-docs 'shell_syntax,tests,gitleaks,lint'
check "forge-docs (kein Eintrag): alle Gates not_configured, ok=false" bash -c "[ \"$(gst shell_syntax)\" = not_configured ] && [ \"$(gst tests)\" = not_configured ] && [ \"$(gst gitleaks)\" = not_configured ] && [ \"$(gst lint)\" = not_configured ] && [ \"$(dj ok)\" = false ]"
check "  ... forge-docs: kein Docker-/Gate-Prozess lief (Logs fehlen)" bash -c "[ -z \"\$(ls '$SCR/gatelogs')\" ]"

# ================= 3. gitleaks (echtes lokales Image, offline) =================
if docker image inspect sha256:e08827d8f64f381ad7120578e30acbd9706caabc56d5f29fe03afbd9077d3b5c >/dev/null 2>&1; then
  mkrepo forge-core3
  # forge-core3 ist NICHT forge-core (kein Tabelleneintrag): das Skript wird direkt im Checkout geprueft, danach ueber ci-gate mit dem Repo forge-core.
  gl() { ( cd "$1" && env -i PATH="$GATEPATH" HOME="$HOME" TMPDIR="$TMPDIR" bash "$OPS/bin/gates/gitleaks" ) > "$T/gl.out" 2>&1; echo $?; }
  check "gitleaks: Repo ohne Funde => Exit 0"                          test "$(gl "$T/work/forge-core3")" = 0
  SECRET="ghp_R7qLm2Xp9ZkVb4NwT8sYc1DfHj6GaE3uKoIz"
  printf 'token = "%s"\n' "$SECRET" > "$T/work/forge-core3/leak.txt"; git -C "$T/work/forge-core3" add leak.txt; git -C "$T/work/forge-core3" commit -q -m leak
  check "gitleaks: Fund => Exit 1"                                     test "$(gl "$T/work/forge-core3")" = 1
  check "  ... Fund maskiert (Klartext nicht in der Ausgabe), Zusammenfassung 'Regel Datei:Zeile'" bash -c "grep -q 'github-pat leak.txt:1' '$T/gl.out' && ! grep -q '$SECRET' '$T/gl.out'"
  # Der Branch versucht sich selbst freizugeben: .gitleaks.toml-Allowlist, .gitleaksignore (Fingerprint), Inline-Freigabe, .gitignore
  printf '[extend]\nuseDefault = true\n[[allowlists]]\npaths = [".*"]\n' > "$T/work/forge-core3/.gitleaks.toml"
  printf '/src/leak.txt:github-pat:1\nleak.txt:github-pat:1\n' > "$T/work/forge-core3/.gitleaksignore"
  printf 'token = "%s" # gitleaks:allow\n' "$SECRET" > "$T/work/forge-core3/leak.txt"; echo leak.txt > "$T/work/forge-core3/.gitignore"
  git -C "$T/work/forge-core3" add -A; git -C "$T/work/forge-core3" commit -q -m selfallow
  check "gitleaks: Selbstfreigabe im Branch (.gitleaks.toml/.gitleaksignore/gitleaks:allow) wirkt NICHT => Exit 1" test "$(gl "$T/work/forge-core3")" = 1
  # Tool-Image fehlt (Override) => Exit 4, kein Gruen
  check "gitleaks: Tool-Image fehlt => Exit 4 (fail closed)"           bash -c "cd '$T/work/forge-core3' && env -i PATH='$GATEPATH' HOME='$HOME' FORGE_GATE_GITLEAKS_IMAGE=sha256:$(printf '0%.0s' $(seq 64)) bash '$OPS/bin/gates/gitleaks'; [ \$? = 4 ]"
  check "gitleaks: Container und Wegwerfverzeichnis aufgeraeumt"      bash -c "[ -z \"\$(docker ps -a --filter name=forge-core-gate-gitleaks -q)\" ] && [ -z \"\$(ls '$TMPDIR' | grep -v '^$')\" ]"
  # etc/gitleaks.toml gibt NUR die benannten synthetischen Fixture-Dateien frei (Pfad im Container /src/...): dieselbe Zeile in einer neuen Datei bleibt ein Fund
  mkrepo forge-core4; mkdir -p "$T/work/forge-core4/tests/fixtures/leak"
  printf 'k = "%s"\n' "$SECRET" > "$T/work/forge-core4/tests/fixtures/leak/config.py"; git -C "$T/work/forge-core4" add -A; git -C "$T/work/forge-core4" commit -q -m fixture
  check "gitleaks: freigegebene Fixture-Datei (tests/fixtures/leak/config.py) => Exit 0"  test "$(gl "$T/work/forge-core4")" = 0
  printf 'k = "%s"\n' "$SECRET" > "$T/work/forge-core4/tests/test_new_fixture.py"; git -C "$T/work/forge-core4" add -A; git -C "$T/work/forge-core4" commit -q -m newfixture
  check "gitleaks: dieselbe Zeile in einer NEUEN Datei => Exit 1 (Allowlist ist dateiweise)" test "$(gl "$T/work/forge-core4")" = 1
  check "  ... Zusammenfassung 'github-pat <Datei>:<Zeile>' ohne Klartext"  bash -c "grep -q 'github-pat tests/test_new_fixture.py:1' '$T/gl.out' && ! grep -q '$SECRET' '$T/gl.out'"
  # Gate ueber ci-gate mit dem Tabelleneintrag von forge-core (argv aus der ausgelieferten Tabelle, Repo-Name forge-core)
  mkrepo forge-core; printf 'token = "%s"\n' "$SECRET" > "$T/work/forge-core/leak.txt"; git -C "$T/work/forge-core" checkout -q feat/x; git -C "$T/work/forge-core" add -A; git -C "$T/work/forge-core" commit -q -m leak; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
  cig_shipped forge-core 'gitleaks'
  check "ci-gate forge-core gitleaks ROT bei Fund (fail), Checkout unveraendert" bash -c "[ \"$(gst gitleaks)\" = fail ] && [ \"$(dj ok)\" = false ]"
  mkrepo forge-core; cig_shipped forge-core 'gitleaks'
  check "ci-gate forge-core gitleaks gruen ohne Fund (pass)"           bash -c "[ \"$(gst gitleaks)\" = pass ] && [ \"$(dj ok)\" = true ]"
else
  skip "gitleaks-Tool-Image lokal nicht vorhanden - gitleaks-Tests uebersprungen"
fi

# ================= 4. tests-Gate mit gestubbtem docker =================
mkrepo forge-core
STUBBIN="$T/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/docker" <<'EOF'
#!/usr/bin/env bash
# Stub: protokolliert jeden Aufruf (eine Zeile) nach $STUB_DIR/calls
printf '%s\n' "$*" >> "$STUB_DIR/calls"
case "$1" in
  build)   echo "$PWD" >> "$STUB_DIR/build.cwd"; echo "stub build output"; exit "${STUB_BUILD_RC:-0}";;
  compose)
    envf=""; shift
    while [ $# -gt 0 ]; do case "$1" in --env-file) envf="$2"; shift 2;; -f|--project-directory|-p|--profile) shift 2;; *) break;; esac; done
    case "$1" in
      run) cp "$envf" "$STUB_DIR/env.copy" 2>/dev/null; env | grep -E '^(FORGE_|IMG_)' | sort > "$STUB_DIR/env.proc"
           if [ -n "${STUB_RUN_LINES:-}" ]; then seq 1 "$STUB_RUN_LINES"; else echo "stub pytest output"; fi
           [ -z "${STUB_RUN_SLEEP:-}" ] || { touch "$STUB_DIR/run.started"; exec sleep "$STUB_RUN_SLEEP"; }
           exit "${STUB_RUN_RC:-0}";;
      down) exit 0;;
      *) echo "UNKNOWN compose verb" >> "$STUB_DIR/unknown"; exit 99;;
    esac;;
  ps)      for a in "$@"; do case "$a" in label=com.docker.compose.project=*) echo "ctr-${a#label=com.docker.compose.project=}";; esac; done; exit 0;;
  network) [ "$2" = ls ] && for a in "$@"; do case "$a" in label=com.docker.compose.project=*) echo "net-${a#label=com.docker.compose.project=}";; esac; done; exit 0;;
  volume)  [ "$2" = ls ] && for a in "$@"; do case "$a" in label=com.docker.compose.project=*) echo "vol-${a#label=com.docker.compose.project=}";; esac; done; exit 0;;
  rm|rmi)  exit 0;;
  *) echo "UNKNOWN $*" >> "$STUB_DIR/unknown"; exit 99;;
esac
EOF
chmod +x "$STUBBIN/docker"
# Gate-Tabelle fuer ci-gate: das tests-Gate von forge-core aus der AUSGELIEFERTEN Tabelle, vorangestellt `env PATH=<stub>:... STUB_*=...`
stubgates() { # stubdir [VAR=val ...] -> Pfad der Tabelle
  local sd="$1"; shift; python3 -I - "$TABLE" "$sd" "$STUBBIN:$GATEPATH" "$@" > "$sd/gates.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["forge-core"]["tests"]
env = ["env", "PATH=" + sys.argv[3], "STUB_DIR=" + sys.argv[2]] + sys.argv[4:]
json.dump({"forge-core": {"tests": {"argv": env + t["argv"], "timeout": t["timeout"]}}}, sys.stdout)
PY
  echo "$sd/gates.json"
}
runstub() { # [VAR=val ...]   -> SD, RC, D; Repo forge-core, Branch feat/x
  N=$((N+1)); SD="$T/stub$N"; mkdir -p "$SD"; touch "$SD/calls"
  cig forge-core 'tests' "$(stubgates "$SD" "$@")"
}
H12=$(git -C "$T/work/forge-core" rev-parse "$HEADX" | cut -c1-12); PROJ="forge-core-gate-$H12"; IMG="forge-core/tests:gate-$H12"
runstub
check "tests-Gate (Stub) gruen: Exit 0, ok=true, pass"                bash -c "[ $RC = 0 ] && [ \"$(dj ok)\" = true ] && [ \"$(gst tests)\" = pass ]"
CALLS="$SD/calls"
check "build: --target test, -t forge-core/tests:gate-<head12>, --pull=false, Pins aus images.lock" bash -c "grep -E '^build ' '$CALLS' | grep -q -- '--pull=false' && grep -E '^build ' '$CALLS' | grep -q -- '--target test' && grep -E '^build ' '$CALLS' | grep -q -- '-t $IMG ' && grep -E '^build ' '$CALLS' | grep -q 'BASE_IMAGE=python@sha256:0*1 ' && grep -E '^build ' '$CALLS' | grep -q 'PG_IMAGE=pgvector/pgvector@sha256:0*2 '"
check "build: cwd == Checkout des Gates (nicht Quell-Repo)"           bash -c "[ \"\$(cat '$SD/build.cwd')\" = \"\$(cd '$SCR/checkout' && pwd -P)\" ]"
check "run: compose -p forge-core-gate-<head12> --profile test run --rm -T tests python -m pytest -p no:cacheprovider -q" bash -c "grep -E '^compose ' '$CALLS' | grep -q -- '-p $PROJ ' && grep -E '^compose .* run ' '$CALLS' | grep -q -- '--profile test run --rm -T tests python -m pytest -p no:cacheprovider -q\$'"
check "Reihenfolge: build vor run; down und rmi nach run"             bash -c "b=\$(grep -n '^build ' '$CALLS' | head -1 | cut -d: -f1); r=\$(grep -n ' run --rm' '$CALLS' | head -1 | cut -d: -f1); d=\$(grep -n ' down -v --remove-orphans' '$CALLS' | tail -1 | cut -d: -f1); i=\$(grep -n '^rmi ' '$CALLS' | tail -1 | cut -d: -f1); [ \$b -lt \$r ] && [ \$r -lt \$d ] && [ \$d -le \$i ]"
check "down -v --remove-orphans mit dem eigenen Projekt, rmi des eigenen Images" bash -c "grep -q 'compose .* -p $PROJ .* down -v --remove-orphans' '$CALLS' && grep -qx 'rmi $IMG' '$CALLS'"
check "Env-Datei: Digest-Pins aus images.lock, FORGE_OPS_DIR=<dieses forge-ops>, REQUIRE_OPS=1, Image-Tag" bash -c "grep -q '^IMG_PYTHON=python@sha256:0*1\$' '$SD/env.copy' && grep -q '^IMG_PGVECTOR=pgvector/pgvector@sha256:0*2\$' '$SD/env.copy' && grep -qx 'FORGE_OPS_DIR=$OPS' '$SD/env.copy' && grep -qx 'FORGE_REQUIRE_OPS=1' '$SD/env.copy' && grep -qx 'FORGE_TESTS_IMAGE=$IMG' '$SD/env.copy' && grep -qx 'FORGE_UID=$(id -u)' '$SD/env.copy'"
check "Prozess-Environment des Compose-Aufrufs: FORGE_OPS_DIR, FORGE_REQUIRE_OPS, FORGE_TESTS_IMAGE" bash -c "grep -qx 'FORGE_OPS_DIR=$OPS' '$SD/env.proc' && grep -qx 'FORGE_REQUIRE_OPS=1' '$SD/env.proc' && grep -qx 'FORGE_TESTS_IMAGE=$IMG' '$SD/env.proc'"
check "Env-Datei liegt AUSSERHALB des Checkouts (Wegwerfverzeichnis), compose.yaml ist die des Checkouts" bash -c "e=\$(grep -E ' run ' '$CALLS' | sed -n 's/.*--env-file \([^ ]*\).*/\1/p'); c=\$(cd '$SCR/checkout' && pwd -P); case \"\$e\" in \"\$c\"/*|'') exit 1;; */forge-gate.*/compose.env) ;; *) exit 1;; esac; grep -E ' run ' '$CALLS' | grep -q -- \"-f \$c/compose.yaml --project-directory \$c \""
check "kein Aufruf ausserhalb der eigenen Namen (Projekt/Image/Label)" bash -c "! grep -v -e '$PROJ' -e '$IMG' '$CALLS' | grep -q . && ! grep -E 'forge-core' '$CALLS' | grep -v -e '$PROJ' -e '$IMG' | grep -q . && [ ! -e '$SD/unknown' ]"
check "kein Zugriff auf /srv/forge, :build-Tags, images.lock in den Aufrufen" bash -c "! grep -E '/srv/forge|:build|images\\.lock|forge-postbote' '$CALLS'"
check "Aufraeum-Sweep nur ueber das eigene Projekt-Label (rm/network rm/volume rm mit abgeleiteten Ids)" bash -c "grep -qx 'rm -f -v ctr-$PROJ' '$CALLS' && grep -qx 'network rm net-$PROJ' '$CALLS' && grep -qx 'volume rm -f vol-$PROJ' '$CALLS' && [ \"\$(grep -c -E '^(rm|network rm|volume rm)' '$CALLS')\" -ge 3 ] && ! grep -E '^(rm|network rm|volume rm|rmi)' '$CALLS' | grep -v -e '$PROJ' -e '$IMG' | grep -q ."
check "Wegwerfverzeichnis des Helfers entfernt, Checkout sauber (kein tree_modified)" bash -c "[ -z \"\$(ls '$SCR/home/tmp')\" ] && [ -z \"\$(git -C '$SCR/checkout' status --porcelain --untracked-files=all)\" ]"
# Namen folgen dem Head: neuer Commit => andere Namen
git -C "$T/work/forge-core" checkout -q feat/x; echo more2 >> "$T/work/forge-core/notes.txt"; git -C "$T/work/forge-core" commit -q -am more2; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
H12B=$(echo "$HEADX" | cut -c1-12)
runstub
check "neuer Head => neue Namen (Projekt/Image mit dem neuen head12)"  bash -c "[ '$H12B' != '$H12' ] && grep -q -- '-p forge-core-gate-$H12B ' '$SD/calls' && grep -qx 'rmi forge-core/tests:gate-$H12B' '$SD/calls' && ! grep -q '$H12' '$SD/calls'"
H12=$H12B; PROJ="forge-core-gate-$H12"; IMG="forge-core/tests:gate-$H12"
# Exit-Weitergabe
runstub STUB_RUN_RC=1
check "pytest-Exit 1 => Gate fail, exit 1, Aufraeumen trotzdem"       bash -c "[ \"$(gst tests)\" = fail ] && [ \"$(dj gates.0.exit)\" = 1 ] && [ \"$(dj ok)\" = false ] && grep -q ' down -v --remove-orphans' '$SD/calls' && grep -qx 'rmi $IMG' '$SD/calls'"
runstub STUB_RUN_RC=5
check "pytest-Exit 5 (keine Tests) => durchgereicht (exit 5), rot"    bash -c "[ \"$(dj gates.0.exit)\" = 5 ] && [ \"$(gst tests)\" = fail ]"
runstub STUB_BUILD_RC=1
check "Build-Fehler => exit 3, rot, KEIN run-Aufruf, Aufraeumen"     bash -c "[ \"$(dj gates.0.exit)\" = 3 ] && [ \"$(gst tests)\" = fail ] && ! grep -q ' run --rm' '$SD/calls' && grep -q ' down -v --remove-orphans' '$SD/calls' && grep -qx 'rmi $IMG' '$SD/calls'"
runstub STUB_RUN_LINES=500
check "Ausgabe begrenzt: 500 Zeilen pytest => Gate-Log <= 70 Zeilen, letzte Zeile 'pytest-Exit 0'" bash -c "[ \$(wc -l < '$SCR/gatelogs/tests.log') -le 70 ] && grep -q '^500\$' '$SCR/gatelogs/tests.log' && ! grep -q '^100\$' '$SCR/gatelogs/tests.log' && tail -n1 '$SCR/gatelogs/tests.log' | grep -q 'pytest-Exit 0'"
# Vorbedingungen: Tag statt Digest in images.lock => Exit 2, kein docker-Aufruf
git -C "$T/work/forge-core" checkout -q feat/x; sed -i 's#^IMG_PYTHON=.*#IMG_PYTHON=python:3.13#' "$T/work/forge-core/images.lock"; git -C "$T/work/forge-core" commit -q -am tagpin; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
runstub
check "images.lock mit Tag statt Digest => Exit 2, kein docker-Aufruf" bash -c "[ \"$(dj gates.0.exit)\" = 2 ] && [ ! -s '$SD/calls' ]"
git -C "$T/work/forge-core" checkout -q feat/x; git -C "$T/work/forge-core" revert --no-edit HEAD >/dev/null; HEADX=$(git -C "$T/work/forge-core" rev-parse HEAD); git -C "$T/work/forge-core" checkout -q main
H12=$(echo "$HEADX" | cut -c1-12); PROJ="forge-core-gate-$H12"; IMG="forge-core/tests:gate-$H12"

waitfor() { local n="$1" i=0; shift; while [ $i -lt $((n*5)) ]; do "$@" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
# ---- SIGTERM / SIGKILL direkt am Helfer (eigene Sitzung wie bei ci-gate): Aufraeumen auch beim Abbruch ----
CO="$T/co"; git clone -q --shared --no-checkout "$T/work/forge-core" "$CO"; git -C "$CO" checkout -q --detach "$HEADX"; mkdir -p "$T/tmp-sig"
sig() { # SIG -> SD, Helfer laeuft mit schlafendem 'run' und bekommt das Signal
  N=$((N+1)); SD="$T/stub$N"; mkdir -p "$SD"; touch "$SD/calls"
  ( cd "$CO" && exec env -i PATH="$STUBBIN:$GATEPATH" HOME="$HOME" TMPDIR="$T/tmp-sig" STUB_DIR="$SD" STUB_RUN_SLEEP=120 setsid bash "$OPS/bin/gates/forge-core-tests" > "$SD/out" 2>&1 ) &
  local i=0; while [ ! -e "$SD/run.started" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  HP=$(pgrep -f "bash $OPS/bin/gates/forge-core-tests$" | head -1)
  kill -"$1" -- "-$HP" 2>/dev/null
  i=0; while ! grep -qx "rmi $IMG" "$SD/calls" && [ $i -lt 60 ]; do sleep 0.2; i=$((i+1)); done
}
sig TERM
check "SIGTERM: down -v --remove-orphans + rmi (eigene Namen) nach dem Signal"  bash -c "grep -q 'compose .* -p $PROJ .* down -v --remove-orphans' '$SD/calls' && grep -qx 'rmi $IMG' '$SD/calls'"
check "  ... Wegwerfverzeichnis weg, Helfer beendet"                    waitfor 15 bash -c "[ -z \"\$(ls -A '$T/tmp-sig')\" ] && ! pgrep -f '[b]ash $OPS/bin/gates/forge-core-tests' >/dev/null"
sig KILL
check "SIGKILL: der abgekoppelte Waechter raeumt auf (down + rmi)"      bash -c "grep -q 'compose .* -p $PROJ .* down -v --remove-orphans' '$SD/calls' && grep -qx 'rmi $IMG' '$SD/calls'"
check "  ... Wegwerfverzeichnis weg, Waechter beendet sich"             waitfor 15 bash -c "[ -z \"\$(ls -A '$T/tmp-sig')\" ] && ! pgrep -f '[f]orge-core-tests __reap' >/dev/null"
pkill -f "sleep 120" 2>/dev/null

echo "---"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [ "$FAIL" = 0 ]
