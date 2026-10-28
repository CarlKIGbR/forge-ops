# Wird vom Postbote (source) vor dem Start von claude/codex eingelesen: Umgebung fuer den Executor-Prozess.
# Geheimnisse kommen nur aus Dateien (0600) und nur ueber die Umgebung des Kindprozesses, nie ueber Argumente, Logs oder Config-Dateien.
FORGE_CORE_SECRETS="${FORGE_CORE_SECRETS:-/srv/forge/work/forge-core/secrets}"
# OTEL: lokaler Collector (forge-core compose `otel-collector`, nur 127.0.0.1:4318, ohne Auth). Die Langfuse-Zugangsdaten liegen ausschliesslich
# im Collector-Container; weder Env noch Config der Executoren enthalten sie.
FORGE_OTEL_ENDPOINT="${FORGE_OTEL_ENDPOINT:-http://127.0.0.1:4318}"

# forge_exec_env <exec: claude|codex> [run_id] [project] [kuerzel]
#   MCP-Token (beide), OTEL nach ARCHITEKTUR §7: Claude per OTEL_*-Variablen, Codex per [otel] in ~/.codex/config.toml (Endpoint des Collectors).
forge_exec_env() {
  local ex="${1:-claude}" run_id="${2:-}" project="${3:-}" kuerzel="${4:-}" f="$FORGE_CORE_SECRETS/mcp_bearer.token" tok=""
  if [ -r "$f" ]; then IFS= read -r tok < "$f" || true; fi
  [ -n "$tok" ] && export FORGE_MCP_TOKEN="$tok"
  unset OTEL_EXPORTER_OTLP_HEADERS FORGE_OTEL_AUTH
  [ -n "$run_id" ] && export FORGE_RUN_ID="$run_id"
  [ -n "$project" ] && export FORGE_PROJECT="$project"        # mem_search-Standardprojekt (Header X-Forge-Project)
  export OTEL_RESOURCE_ATTRIBUTES="forge.run_id=${run_id},forge.project=${project},forge.kuerzel=${kuerzel}"
  export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
  if [ "$ex" = codex ]; then
    unset CLAUDE_CODE_ENABLE_TELEMETRY CLAUDE_CODE_ENHANCED_TELEMETRY_BETA OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_ENDPOINT   # Codex nutzt [otel] aus config.toml
  else
    export CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 OTEL_TRACES_EXPORTER=otlp
    export OTEL_EXPORTER_OTLP_ENDPOINT="$FORGE_OTEL_ENDPOINT"
  fi
  return 0
}

# Trockenlauf: nur Namen und maskierte Werte (<masked:N chars>) der relevanten Variablen
forge_exec_env_dryrun() {
  local ex="${1:-claude}" v val
  ( forge_exec_env "$ex" "${2:-20261028T000000Z_BRIEF_x.md}" "${3:-forge}" "${4:-forge-x}"
    for v in FORGE_MCP_TOKEN FORGE_RUN_ID FORGE_PROJECT CLAUDE_CODE_ENABLE_TELEMETRY CLAUDE_CODE_ENHANCED_TELEMETRY_BETA OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_PROTOCOL \
             OTEL_EXPORTER_OTLP_ENDPOINT OTEL_RESOURCE_ATTRIBUTES OTEL_EXPORTER_OTLP_HEADERS FORGE_OTEL_AUTH; do
      val="${!v-}"
      if [ -z "$val" ]; then echo "$v=<unset>"
      else case "$v" in
        FORGE_MCP_TOKEN|OTEL_EXPORTER_OTLP_HEADERS|FORGE_OTEL_AUTH) echo "$v=<masked:${#val} chars>" ;;
        *) echo "$v=$val" ;;
      esac; fi
    done )
}
