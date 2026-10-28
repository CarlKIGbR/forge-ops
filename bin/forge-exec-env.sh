# Wird vom Postbote (source) vor dem Start von claude/codex eingelesen: Umgebung fuer den Executor-Prozess.
# Geheimnisse kommen nur aus Dateien (0600) und nur ueber die Umgebung des Kindprozesses, nie ueber Argumente/Logs.
FORGE_CORE_SECRETS="${FORGE_CORE_SECRETS:-/srv/forge/work/forge-core/secrets}"

forge_exec_env() {   # forge_exec_env <exec>
  local f="$FORGE_CORE_SECRETS/mcp_bearer.token" tok=""
  if [ -r "$f" ]; then IFS= read -r tok < "$f" || true; fi
  [ -n "$tok" ] && export FORGE_MCP_TOKEN="$tok"
  return 0
}
