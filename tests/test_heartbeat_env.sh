#!/usr/bin/env bash
# Heartbeat waehrend eines laufenden Auftrags + Executor-Umgebung (MCP-Token, OTEL) mit Stub-claude/-codex; keine echten Geheimnisse.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/../bin/forge-postbote.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }

export FORGE_BASE="$T/base" FORGE_MIN_AGE=0 FORGE_POLL=1 FORGE_HB_INTERVAL=1
mkdir -p "$T/sec/core" "$T/sec/fund" "$FORGE_BASE/post/eingang"
printf 'mcp-token-AAAA\n' > "$T/sec/core/mcp_bearer.token"
printf 'LANGFUSE_HOST=http://x\nLANGFUSE_PUBLIC_KEY=pk-lf-test\nLANGFUSE_SECRET_KEY=sk-lf-test\n' > "$T/sec/fund/langfuse-client.env"   # darf nicht mehr gelesen werden
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic leaked-from-parent" FORGE_OTEL_AUTH="Basic leaked-from-parent"
export FORGE_CORE_SECRETS="$T/sec/core" FUNDAMENT_SECRETS="$T/sec/fund" STUB_LOG="$T/stub.log" HBFILE="$FORGE_BASE/post/state/heartbeat"
CLAUDE_BIN="$T/claude"; CODEX_BIN="$T/codex"; export CLAUDE_BIN CODEX_BIN
cat > "$CLAUDE_BIN" <<'S'
#!/usr/bin/env bash
cat >/dev/null
for i in 1 2 3 4; do sleep 1; cat "$HBFILE" >> "$STUB_LOG.hb" 2>/dev/null; done
{ echo "CLAUDE_TEL=${CLAUDE_CODE_ENABLE_TELEMETRY:-}"; echo "ENH=${CLAUDE_CODE_ENHANCED_TELEMETRY_BETA:-}"; echo "EXP=${OTEL_TRACES_EXPORTER:-}"; echo "PROTO=${OTEL_EXPORTER_OTLP_PROTOCOL:-}"
  echo "EP=${OTEL_EXPORTER_OTLP_ENDPOINT:-}"; echo "RA=${OTEL_RESOURCE_ATTRIBUTES:-}"; echo "HDR=${OTEL_EXPORTER_OTLP_HEADERS:-}"; echo "MCP=${FORGE_MCP_TOKEN:-}"; echo "ARGV=$*"; } > "$STUB_LOG.claude"
printf '{"type":"result","subtype":"success","session_id":"sid-1","result":"PONG","total_cost_usd":0.01}\n'
S
cat > "$CODEX_BIN" <<'S'
#!/usr/bin/env bash
cat >/dev/null
{ echo "AUTH=${FORGE_OTEL_AUTH:-}"; echo "RA=${OTEL_RESOURCE_ATTRIBUTES:-}"; echo "TEL=${CLAUDE_CODE_ENABLE_TELEMETRY:-}"; echo "MCP=${FORGE_MCP_TOKEN:-}"; echo "ARGV=$*"; } > "$STUB_LOG.codex"
echo '{"type":"thread.started","thread_id":"019aaaaa-0000-7000-8000-000000000001"}'
echo '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"ok"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
S
chmod +x "$CLAUDE_BIN" "$CODEX_BIN"

echo hi > "$FORGE_BASE/post/eingang/BRIEF_forge-t9.md"
bash "$WATCHER" --once >/dev/null 2>&1
n=$(sort -u "$STUB_LOG.hb" 2>/dev/null | wc -l)
[ "$n" -ge 2 ] && ok "Heartbeat aendert sich waehrend des Laufs ($n verschiedene Werte)" || bad "Heartbeat blieb stehen ($n)"

get() { sed -n "s/^$1=//p" "$STUB_LOG.claude"; }
[ "$(get CLAUDE_TEL)" = 1 ] && [ "$(get ENH)" = 1 ] && [ "$(get EXP)" = otlp ] && [ "$(get PROTO)" = http/protobuf ] && ok "claude: OTEL-Variablen nach ARCHITEKTUR §7" || bad "claude OTEL-Variablen"
[ "$(get EP)" = "http://127.0.0.1:4318" ] && ok "claude: Endpoint = lokaler Collector" || bad "Endpoint $(get EP)"
exp=$(printf 'pk-lf-test:sk-lf-test' | base64 -w0)
[ -z "$(get HDR)" ] && ok "claude: kein OTLP-Auth-Header (auch nicht aus dem Elternprozess)" || bad "Header gesetzt"
ra=$(get RA)
[[ "$ra" =~ ^forge\.run_id=[0-9]{8}T[0-9]{6}Z_BRIEF_forge-t9\.md,forge\.project=forge,forge\.kuerzel=forge-t9$ ]] && ok "OTEL_RESOURCE_ATTRIBUTES run_id/project/kuerzel" || bad "RA=$ra"
[ "$(get MCP)" = mcp-token-AAAA ] && ok "claude: FORGE_MCP_TOKEN aus Datei" || bad "MCP-Token"
grep -q 'mcp-token-AAAA\|sk-lf-test\|'"$exp" <<<"$(get ARGV)" && bad "Geheimnis in argv" || ok "kein Geheimnis in argv"
grep -rq 'mcp-token-AAAA\|sk-lf-test\|'"$exp" "$FORGE_BASE/post/log" "$FORGE_BASE/post/ausgang" 2>/dev/null && bad "Geheimnis in Log/Report" || ok "kein Geheimnis in Log/Report"

echo hi > "$FORGE_BASE/post/eingang/BRIEF_forge-t9.exec-codex.md"
bash "$WATCHER" --once >/dev/null 2>&1
c() { sed -n "s/^$1=//p" "$STUB_LOG.codex"; }
[ -z "$(c AUTH)" ] && [ -z "$(c TEL)" ] && ok "codex: keine OTEL-Zugangsdaten in der Umgebung, keine Claude-Telemetrie" || bad "codex env"
[ "$(c MCP)" = mcp-token-AAAA ] && ok "codex: FORGE_MCP_TOKEN" || bad "codex MCP"

# Regression: der Heartbeat-Hintergrund darf Pipes des Aufrufers nicht offenhalten (subprocess capture_output haengt sonst bis zum sleep-Ende)
echo hi > "$FORGE_BASE/post/eingang/BRIEF_forge-t9b.md"
t0=$(date +%s); FORGE_HB_INTERVAL=30 bash "$WATCHER" --once 2>&1 | cat >/dev/null; el=$(( $(date +%s) - t0 ))
[ "$el" -lt 15 ] && ok "Watcher-Lauf haelt keine Pipe offen (${el}s)" || bad "Pipe offen: ${el}s"

# R7: Standard-Intervall strikt unter 60 s (Scheduling-Overhead)
def=$(sed -n 's/.*FORGE_HB_INTERVAL:-\([0-9]*\)}.*/\1/p' "$WATCHER" | head -n1)
[ -n "$def" ] && [ "$def" -le 50 ] && ok "Heartbeat-Standardintervall ${def}s < 60s" || bad "Heartbeat-Standard ${def:-?}"

# Trockenlauf: nur Namen + maskierte Werte
out=$(bash -c '. "$1"; forge_exec_env_dryrun claude 2026T_BRIEF_x.md forge forge-x' _ "$HERE/../bin/forge-exec-env.sh")
grep -q 'OTEL_EXPORTER_OTLP_HEADERS=<unset>' <<<"$out" && grep -q 'FORGE_MCP_TOKEN=<masked:' <<<"$out" && ! grep -q "$exp\|sk-lf-test\|mcp-token\|leaked" <<<"$out" && ok "dryrun: maskiert, keine OTEL-Auth" || bad "dryrun: $out"
echo "---- $pass bestanden, $fail fehlgeschlagen"; [ "$fail" = 0 ]
