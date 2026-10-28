#!/usr/bin/env bash
# End-to-end-Test des Postboten mit Stub-claude und Stub-codex (kein Netz, keine Auth).
# Aufruf: tests/test_postbote.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/../bin/forge-postbote.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FORGE_BASE="$T/base" FORGE_MIN_AGE=0 FORGE_POLL=1
CLAUDE_BIN="$T/claude"; CODEX_BIN="$T/codex"; export CLAUDE_BIN CODEX_BIN
mkdir -p "$FORGE_BASE"

cat > "$CLAUDE_BIN" <<'S'
#!/usr/bin/env bash
{ echo "ARGV: $*"; echo "CWD: $PWD"; echo "STDIN: $(cat)"; } >> "$STUB_LOG"
sid="claude-sid-1"; for ((i=1;i<=$#;i++)); do [ "${!i}" = --resume ] && { j=$((i+1)); sid="${!j}"; }; done
printf '{"type":"result","subtype":"success","session_id":"%s","result":"claude-antwort","total_cost_usd":0.0123}\n' "$sid"
S
cat > "$CODEX_BIN" <<'S'
#!/usr/bin/env bash
{ echo "ARGV: $*"; echo "CWD: $PWD"; echo "STDIN: $(cat)"; } >> "$STUB_LOG"
tid="019aaaaa-0000-7000-8000-000000000001"
if [ "${2:-}" = resume ]; then for a in "$@"; do [[ "$a" =~ ^019 ]] && tid="$a"; done; fi
echo "2026-01-01T00:00:00Z WARN irgendein Log auf stdout"
printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
echo '{"type":"turn.started"}'
echo '{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"denke"}}'
echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"codex-antwort"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5}}'
S
chmod +x "$CLAUDE_BIN" "$CODEX_BIN"
export STUB_LOG="$T/stub.log"

PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1 -- $2"; FAIL=$((FAIL+1)); }
check() { # name cmd...
  local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n" "$*"; fi
}
run() { # Dateiname -> sendet Brief, laeuft eine Runde, setzt R (Reportpfad), L (Stub-Log dieses Laufs)
  : > "$STUB_LOG"
  mkdir -p "$FORGE_BASE/post/eingang"; printf 'Inhalt von %s\n' "$1" > "$FORGE_BASE/post/eingang/$1"
  bash "$WATCHER" --once
  R=$(ls -t "$FORGE_BASE"/post/ausgang/REPORT_* | head -n1); L=$(cat "$STUB_LOG")
  sleep 1   # Zeitstempel im Reportnamen eindeutig halten
}
S="$FORGE_BASE/post/state"

# 1 claude brief
run BRIEF_T1.md
check "claude brief: argv -p/json/bypass"     grep -q -- '-p --output-format json --permission-mode bypassPermissions' <<<"$L"
check "claude brief: laeuft in work/"         grep -q "CWD: $FORGE_BASE/work" <<<"$L"
check "claude brief: Brief per stdin"         grep -q 'STDIN: Inhalt von BRIEF_T1.md' <<<"$L"
check "claude brief: Executor: claude + cost" bash -c "grep -q '^Executor: claude' '$R' && grep -q 'cost_usd: 0.0123' '$R' && grep -q claude-antwort '$R'"
check "claude brief: state session+exec"      bash -c "[ \"\$(cat $S/T1.session)\" = claude-sid-1 ] && [ \"\$(cat $S/T1.exec)\" = claude ]"
check "claude brief: kein --effort ohne aufwand" bash -c "! grep -q -- '--effort' <<<\"\$1\"" _ "$L"

# 2 claude fortsetzung
run BRIEF_T1.fortsetzung.md
check "claude fortsetzung: --resume claude-sid-1" grep -q -- '--resume claude-sid-1' <<<"$L"
check "claude fortsetzung: Report ok"             grep -q 'Exit-Code: 0' "$R"

# 3 codex brief (mit modell + aufwand)
run BRIEF_T2.exec-codex.aufwand-high.modell-gpt-5.5-codex.md
check "codex brief: argv exec/json/skip/bypass" grep -q -- 'exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox' <<<"$L"
check "codex brief: aufwand -c model_reasoning_effort=high" grep -q -- '-c model_reasoning_effort=high' <<<"$L"
check "codex brief: -m modell"       grep -q -- '-m gpt-5.5-codex' <<<"$L"
check "codex brief: stdin via '-'"   bash -c "grep -q -- ' -\$' <<<\"\$(grep ARGV <<<\"\$1\")\" && grep -q 'STDIN: Inhalt von BRIEF_T2' <<<\"\$1\"" _ "$L"
check "codex brief: CWD work/"       grep -q "CWD: $FORGE_BASE/work" <<<"$L"
check "codex brief: Report Executor/Antwort/Usage" bash -c "grep -q '^Executor: codex' '$R' && grep -q codex-antwort '$R' && grep -q 'usage (tokens): in=100 cached=40 out=20 reasoning=5' '$R' && grep -q 'Aufwand: high' '$R'"
check "codex brief: Log-Zeile auf stdout ignoriert" bash -c "! grep -q WARN '$R'"
check "codex brief: state thread+exec" bash -c "[ \"\$(cat $S/T2.session)\" = 019aaaaa-0000-7000-8000-000000000001 ] && [ \"\$(cat $S/T2.exec)\" = codex ]"

# 4 codex fortsetzung
run BRIEF_T2.fortsetzung.exec-codex.md
check "codex fortsetzung: exec resume ... <thread> -" grep -q -- 'ARGV: exec resume --json .* 019aaaaa-0000-7000-8000-000000000001 -$' <<<"$L"
check "codex fortsetzung: Report Executor codex" grep -q '^Executor: codex' "$R"

# 5 exec mismatch (T2 ist codex, Fortsetzung ohne .exec = claude)
run BRIEF_T2.fortsetzung.md
check "mismatch: kein Executor-Aufruf"   test -z "$L"
check "mismatch: Report ABGELEHNT"       grep -q 'ABGELEHNT' "$R"
check "mismatch: Session unveraendert"   bash -c "[ \"\$(cat $S/T2.exec)\" = codex ]"
run BRIEF_T1.fortsetzung.exec-codex.md
check "mismatch (claude-Session, exec-codex): abgelehnt" bash -c "test -z \"\$1\" && grep -q ABGELEHNT '$R'" _ "$L"

# 6 falsche Reihenfolge / ungueltige Werte
for n in BRIEF_T3.modell-x.exec-codex.md BRIEF_T3.exec-codex.fortsetzung.md BRIEF_T3.aufwand-high.exec-codex.md BRIEF_T3.exec-gemini.md BRIEF_T3.aufwand-extrem.md; do
  run "$n"
  check "reihenfolge/wert abgelehnt: $n" bash -c "test -z \"\$1\" && grep -q 'ABGELEHNT (Dateiname' '$R'" _ "$L"
done

# 7 aufwand bei claude, v1-Kompatibilitaet (Session ohne .exec = claude), modell-only
run BRIEF_T4.aufwand-medium.modell-sonnet.md
check "claude aufwand: --effort medium + --model" bash -c "grep -q -- '--model sonnet' <<<\"\$1\" && grep -q -- '--effort medium' <<<\"\$1\"" _ "$L"
rm -f "$S/T4.exec"
run BRIEF_T4.fortsetzung.md
check "v1-Session ohne .exec -> claude-Fortsetzung ok" grep -q -- '--resume claude-sid-1' <<<"$L"

# 8 Fortsetzung ohne Session
run BRIEF_T9.fortsetzung.exec-codex.md
check "fortsetzung ohne Session: Fehlerreport, kein Aufruf" bash -c "test -z \"\$1\" && grep -q 'keine Session' '$R'" _ "$L"

echo "---- $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" = 0 ]
