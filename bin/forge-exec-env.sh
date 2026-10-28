# Wird vom Postbote (source) vor dem Start von claude/codex eingelesen: Umgebung fuer den Executor-Prozess.
# Geheimnisse kommen nur aus Dateien (0600) und nur ueber die Umgebung des Kindprozesses, nie ueber Argumente, Logs oder Config-Dateien.
FORGE_CORE_SECRETS="${FORGE_CORE_SECRETS:-/srv/forge/work/forge-core/secrets}"
FUNDAMENT_SECRETS="${FUNDAMENT_SECRETS:-/srv/forge/work/fundament/secrets}"
FORGE_OTEL_ENDPOINT="${FORGE_OTEL_ENDPOINT:-http://127.0.0.1:3000/api/public/otel}"

# Wert einer KEY=VALUE-Zeile aus einer Env-Datei (ohne die Datei zu 'sourcen')
_envfile_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }

# forge_exec_env <exec: claude|codex> [run_id] [project] [kuerzel]
#   MCP-Token (beide), OTEL nach ARCHITEKTUR §7: Claude per OTEL_*-Variablen, Codex per [otel] in config.toml (Header ueber ${FORGE_OTEL_AUTH}).
forge_exec_env() {
  local ex="${1:-claude}" run_id="${2:-}" project="${3:-}" kuerzel="${4:-}" f="$FORGE_CORE_SECRETS/mcp_bearer.token" tok="" pk sk auth
  if [ -r "$f" ]; then IFS= read -r tok < "$f" || true; fi
  [ -n "$tok" ] && export FORGE_MCP_TOKEN="$tok"
  pk=$(_envfile_get "$FUNDAMENT_SECRETS/langfuse-client.env" LANGFUSE_PUBLIC_KEY)
  sk=$(_envfile_get "$FUNDAMENT_SECRETS/langfuse-client.env" LANGFUSE_SECRET_KEY)
  [ -n "$run_id" ] && export FORGE_RUN_ID="$run_id"
  if [ -n "$pk" ] && [ -n "$sk" ]; then
    auth="Basic $(printf '%s:%s' "$pk" "$sk" | base64 -w0)"
    export OTEL_RESOURCE_ATTRIBUTES="forge.run_id=${run_id},forge.project=${project},forge.kuerzel=${kuerzel}"
    export OTEL_EXPORTER_OTLP_ENDPOINT="$FORGE_OTEL_ENDPOINT" OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
    if [ "$ex" = codex ]; then
      export FORGE_OTEL_AUTH="$auth"            # config.toml [otel] referenziert ${FORGE_OTEL_AUTH}
    else
      export CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 OTEL_TRACES_EXPORTER=otlp
      export OTEL_EXPORTER_OTLP_HEADERS="Authorization=${auth}"
    fi
  fi
  return 0
}

# Trockenlauf: nur Namen und maskierte Werte (<masked:N chars>) der relevanten Variablen
forge_exec_env_dryrun() {
  local ex="${1:-claude}" v val
  ( forge_exec_env "$ex" "${2:-20261028T000000Z_BRIEF_x.md}" "${3:-forge}" "${4:-forge-x}"
    for v in FORGE_MCP_TOKEN FORGE_RUN_ID CLAUDE_CODE_ENABLE_TELEMETRY CLAUDE_CODE_ENHANCED_TELEMETRY_BETA OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_PROTOCOL \
             OTEL_EXPORTER_OTLP_ENDPOINT OTEL_RESOURCE_ATTRIBUTES OTEL_EXPORTER_OTLP_HEADERS FORGE_OTEL_AUTH; do
      val="${!v-}"
      if [ -z "$val" ]; then echo "$v=<unset>"
      else case "$v" in
        FORGE_MCP_TOKEN|OTEL_EXPORTER_OTLP_HEADERS|FORGE_OTEL_AUTH) echo "$v=<masked:${#val} chars>" ;;
        *) echo "$v=$val" ;;
      esac; fi
    done )
}
