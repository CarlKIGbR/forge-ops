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
printf 'LANGFUSE_HOST=http://x\nLANGFUSE_PUBLIC_KEY=pk-lf-test\nLANGFUSE_SECRET_KEY=sk-lf-test\n' > "$T/sec/fund/langfuse-client.env"
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
[ "$(get EP)" = "http://127.0.0.1:3000/api/public/otel" ] && ok "claude: Endpoint" || bad "Endpoint $(get EP)"
exp=$(printf 'pk-lf-test:sk-lf-test' | base64 -w0)
[ "$(get HDR)" = "Authorization=Basic $exp" ] && ok "claude: Basic-Header nur in der Umgebung" || bad "Header"
ra=$(get RA)
[[ "$ra" =~ ^forge\.run_id=[0-9]{8}T[0-9]{6}Z_BRIEF_forge-t9\.md,forge\.project=forge,forge\.kuerzel=forge-t9$ ]] && ok "OTEL_RESOURCE_ATTRIBUTES run_id/project/kuerzel" || bad "RA=$ra"
[ "$(get MCP)" = mcp-token-AAAA ] && ok "claude: FORGE_MCP_TOKEN aus Datei" || bad "MCP-Token"
grep -q 'mcp-token-AAAA\|sk-lf-test\|'"$exp" <<<"$(get ARGV)" && bad "Geheimnis in argv" || ok "kein Geheimnis in argv"
grep -rq 'mcp-token-AAAA\|sk-lf-test\|'"$exp" "$FORGE_BASE/post/log" "$FORGE_BASE/post/ausgang" 2>/dev/null && bad "Geheimnis in Log/Report" || ok "kein Geheimnis in Log/Report"

echo hi > "$FORGE_BASE/post/eingang/BRIEF_forge-t9.exec-codex.md"
bash "$WATCHER" --once >/dev/null 2>&1
c() { sed -n "s/^$1=//p" "$STUB_LOG.codex"; }
[ "$(c AUTH)" = "Basic $exp" ] && [ -z "$(c TEL)" ] && ok "codex: FORGE_OTEL_AUTH gesetzt, keine Claude-Telemetrie" || bad "codex env"
[ "$(c MCP)" = mcp-token-AAAA ] && ok "codex: FORGE_MCP_TOKEN" || bad "codex MCP"

# Trockenlauf: nur Namen + maskierte Werte
out=$(bash -c '. "$1"; forge_exec_env_dryrun claude 2026T_BRIEF_x.md forge forge-x' _ "$HERE/../bin/forge-exec-env.sh")
grep -q 'OTEL_EXPORTER_OTLP_HEADERS=<masked:' <<<"$out" && ! grep -q "$exp\|sk-lf-test\|mcp-token" <<<"$out" && ok "dryrun maskiert Geheimnisse" || bad "dryrun: $out"
echo "---- $pass bestanden, $fail fehlgeschlagen"; [ "$fail" = 0 ]
