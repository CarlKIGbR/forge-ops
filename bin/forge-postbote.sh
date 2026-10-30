#!/usr/bin/env bash
# forge-postbote.sh - Postbote (Watcher) fuer das forge-post Postfach.
# Laeuft als User "forge". Nimmt Briefe aus eingang/, ruft "claude -p" auf,
# schreibt Reports nach ausgang/. Strikt sequentiell (flock), Poll alle 5 s.
#
# Dateiname: <ART>_<K>[.fortsetzung][.exec-<claude|codex>][.aufwand-<minimal|low|medium|high|xhigh>][.modell-<id>][.n-<8 hex>].md
#   ART = BRIEF|WEISUNG|NACHFORDERUNG|GO|PING ; K = [A-Za-z0-9-]+
#   Reihenfolge fest wie oben; .modell- steht vor dem optionalen Nonce .n-<8 hex> (Einwurf-Kennung, lowercase hex), der direkt vor .md steht. Default exec = claude.
#   exec-codex: "codex exec --json ..." (Thread-ID aus thread.started, Antwort aus
#   item.completed/agent_message, Tokens aus turn.completed.usage).
#   Report-Kopf enthaelt "- Run-ID: <ts>_<name>" (= erledigt/-Archivname); Archivierung erfolgt VOR dem Report.
#   state/<K>.session = Session/Thread-ID, state/<K>.exec = Executor.
#   aufwand: codex -> -c model_reasoning_effort=<x>; claude -> --effort (minimal wird low).
#
# Umgebung: FORGE_BASE (Default /srv/forge), FORGE_MAX_SECONDS (14400),
#           FORGE_PERMISSION_MODE (bypassPermissions), FORGE_POLL (5),
#           FORGE_MIN_AGE (3), CLAUDE_BIN (claude), CODEX_BIN (codex)
# Neustart: bin/forge-request-restart.sh "<grund>" (Flag state/restart-requested, wirkt nur zwischen Runs). SIGTERM waehrend eines Runs wird bis zu dessen Ende aufgeschoben.
# STOP (F5b): existiert $POST/control/STOP (FORGE_STOP_FILE), beginnt der Watcher KEINEN neuen Brief (Pruefung unmittelbar vor der Auswahl des naechsten Briefs; er pollt
#   weiter, Heartbeat laeuft, Restart-Anforderungen werden bedient) und loggt einmal "paused by STOP" / "resumed". Laufende Briefe werden nicht beendet (F5c).
#   Setzen/Loesen am Host bevorzugt mit bin/forge-stop / bin/forge-release (nehmen das Dispatch-Lock control/.dispatch.lock).
#   Start eines Briefs = "letzte STOP-Pruefung -> Executor starten" laeuft UNTER DEMSELBEN flock (control/.dispatch.lock, FD 8): ist STOP im Lock gesetzt, wird der Brief nicht
#   angefasst (bleibt in eingang/, "paused by STOP"). Das Lock wird nach dem Spawn freigegeben (Laeufe dauern Stunden). forge-stop wartet auf das Lock => entweder
#   startete der Brief vor STOP (laeuft weiter, F5c) oder gar nicht. Ein rohes `touch STOP` ohne forge-stop ist best effort: garantiert nur fuer Briefs, deren gesperrte
#   Startpruefung nach dem touch liegt. Test-Haken (nur Tests): FORGE_HOOK_AFTER_SELECT / FORGE_HOOK_IN_CLAIM = ausfuehrbare Datei, nach der Auswahl bzw. im Lock-Abschnitt.
# Flags: --once  (eine Runde: alle faelligen Briefe abarbeiten, dann Ende)
set -u

BASE="${FORGE_BASE:-/srv/forge}"
POST="$BASE/post"
WORK="$BASE/work"
POLL="${FORGE_POLL:-5}"
MIN_AGE="${FORGE_MIN_AGE:-3}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"
ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1
# Executor-Umgebung (MCP-Token, spaeter OTEL) aus forge-exec-env.sh
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/forge-exec-env.sh" 2>/dev/null || forge_exec_env() { :; }

umask 0002
export PATH="${HOME:-/srv/forge/home}/.local/bin:$PATH"

RESTART_FLAG="$POST/state/restart-requested"
STOP_FILE="${FORGE_STOP_FILE:-$POST/control/STOP}"; PAUSED=0
LOCK_FILE="${FORGE_DISPATCH_LOCK:-$POST/control/.dispatch.lock}"; LOCKED=0
EIN="$POST/eingang"; AUS="$POST/ausgang"; ERL="$POST/erledigt"
LOGD="$POST/log"; STATE="$POST/state"
mkdir -p "$EIN" "$AUS" "$ERL" "$LOGD" "$STATE" "$WORK" || { echo "FEHLER: Verzeichnisse nicht anlegbar unter $BASE" >&2; exit 1; }

# Nur eine Instanz gleichzeitig
exec 9>"$STATE/.lock"
if ! flock -n 9; then
  echo "Postbote laeuft bereits (flock auf $STATE/.lock)" >&2
  exit 1
fi

STOP=0
TERMS=0
CHILD=""
# Erstes SIGTERM/SIGINT: nichts Neues beginnen, laufenden Auftrag zu Ende fuehren (Report/Archiv/Log), danach Ende.
# Zweites Signal: laufenden Auftrag beenden (SIGTERM an den Kindprozess). Der Unit-Stop-Timeout (SIGKILL) bleibt als letzte Instanz.
# shellcheck disable=SC2329
on_term() {
  STOP=1; TERMS=$((TERMS + 1))
  if [ "$TERMS" -ge 2 ]; then
    [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
    hb_stop
  fi
}
trap on_term TERM INT

utc()  { date -u +%Y%m%dT%H%M%SZ; }
utcl() { date -u +%Y-%m-%dT%H:%M:%SZ; }

HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# json_get <datei> <feld>  -> Wert oder leer; bei Array-Ausgabe letztes "result"-Objekt
json_get() {
  local f="$1" key="$2"
  if [ "$HAVE_JQ" = 1 ]; then
    jq -r --arg k "$key" '(if type=="array" then (map(select(type=="object" and .type=="result"))|last) else . end) | (.[$k] // empty) | tostring' "$f" 2>/dev/null
  else
    python3 - "$f" "$key" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
if isinstance(d,list):
    r=[x for x in d if isinstance(x,dict) and x.get("type")=="result"]
    d=r[-1] if r else {}
v=d.get(sys.argv[2])
if v is not None: print(v if isinstance(v,str) else json.dumps(v))
PY
  fi
}

# codex_parse <jsonl> <thread|text|usage|error>
#   thread: erste thread.started.thread_id; text: letzte agent_message (item.completed);
#   usage: letztes turn.completed.usage; error: letzte turn.failed/error-Meldung.
#   Nicht-JSON-Zeilen (Log-Ausgaben auf stdout) werden ignoriert.
codex_parse() {
  python3 -I - "$1" "$2" <<'PY' 2>/dev/null
import json,sys
thread=text=usage=err=None
for line in open(sys.argv[1],errors="replace"):
    line=line.strip()
    if not line.startswith("{"): continue
    try: e=json.loads(line)
    except Exception: continue
    if not isinstance(e,dict): continue
    t=e.get("type")
    if t=="thread.started" and thread is None: thread=e.get("thread_id")
    elif t=="item.completed":
        it=e.get("item") or {}
        if it.get("type")=="agent_message" and it.get("text"): text=it["text"]
    elif t=="turn.completed":
        u=e.get("usage") or {}
        usage="in=%s cached=%s out=%s reasoning=%s"%(u.get("input_tokens","-"),u.get("cached_input_tokens","-"),u.get("output_tokens","-"),u.get("reasoning_output_tokens","-"))
    elif t=="turn.failed": err=(e.get("error") or {}).get("message") or "turn.failed"
    elif t=="error" and not err: err=e.get("message")
v={"thread":thread,"text":text,"usage":usage,"error":err}[sys.argv[2]]
if v: print(v)
PY
}

# write_report <ziel> <kopf-datei> <body-datei>   (atomar: .teil -> mv)
write_report() {
  local dst="$1" head="$2" body="$3"
  { cat "$head"; echo; cat "$body"; } > "$dst.teil" && mv -f "$dst.teil" "$dst"
}

heartbeat() {
  utcl > "$STATE/.heartbeat.tmp" && mv -f "$STATE/.heartbeat.tmp" "$STATE/heartbeat"
}

# Solange ein Auftrag laeuft, alle FORGE_HB_INTERVAL s (45; Abstand inkl. Overhead <= 50) einen Heartbeat schreiben (sonst "stale" bei langen Runs)
HBPID=""
hb_start() {
  # stdout/stderr/Lock-FD schliessen: ein verwaister sleep darf weder Pipes des Aufrufers noch den flock halten
  ( while kill -0 "$$" 2>/dev/null; do sleep "${FORGE_HB_INTERVAL:-45}" >/dev/null 2>&1 9>&- & wait $!; kill -0 "$$" 2>/dev/null && heartbeat; done ) >/dev/null 2>&1 9>&- &
  HBPID=$!
}
hb_stop() {
  [ -n "$HBPID" ] || return 0
  kill "$HBPID" 2>/dev/null; wait "$HBPID" 2>/dev/null; HBPID=""
}

# Naechsten faelligen Brief liefern (aeltester zuerst, mtime >= MIN_AGE s, keine Dotfiles)
next_brief() {
  local now mt name
  now=$(date +%s)
  while IFS=' ' read -r mt name; do
    [ -z "$name" ] && continue
    mt="${mt%%.*}"
    if [ $((now - mt)) -ge "$MIN_AGE" ]; then
      printf '%s\n' "$name"; return 0
    fi
  done < <(find "$EIN" -maxdepth 1 -type f -name '*.md' ! -name '.*' -printf '%T@ %f\n' 2>/dev/null | sort -n)
  return 1
}

# claim_lock: Dispatch-Lock nehmen, dann STOP pruefen. 0 = gesperrt + kein STOP (Aufrufer muss unclaim rufen); 1 = STOP (Lock frei); 2 = Lock nicht verfuegbar (fail closed).
# Ohne Control-Verzeichnis (aeltere Installation) gibt es weder STOP noch Lock: 0 ohne Lock.
claim_lock() {
  if [ -d "$(dirname "$LOCK_FILE")" ]; then
    exec 8>>"$LOCK_FILE" 2>/dev/null || return 2
    flock -w "${FORGE_LOCK_TIMEOUT:-10}" 8 || { exec 8>&-; return 2; }
    LOCKED=1
  fi
  if [ -e "$STOP_FILE" ] || [ -L "$STOP_FILE" ]; then unclaim; return 1; fi
  if [ -n "${FORGE_HOOK_IN_CLAIM:-}" ] && [ -x "$FORGE_HOOK_IN_CLAIM" ]; then "$FORGE_HOOK_IN_CLAIM" 8>&-; fi
  return 0
}
unclaim() {   # LOCK_UN wirkt auf die offene Dateibeschreibung, also auch dann, wenn ein Kindprozess die FD noch geerbt hat
  [ "$LOCKED" = 1 ] || return 0
  flock -u 8 2>/dev/null; exec 8>&-; LOCKED=0
}

process() {
  local name="$1" base art k fort model nonce="" exec aufwand oldexec="" rejected=0 sid="" start end t0 t1 dur rc=0
  local ts run json err head body cost reportname
  base="${name%.md}"
  claim_lock; local c=$?
  [ "$c" = 0 ] || return $((70 + c))   # 71 = STOP, 72 = Lock nicht verfuegbar: Brief unangetastet in eingang/
  ts=$(utc)
  head=$(mktemp "$STATE/.head.XXXXXX"); body=$(mktemp "$STATE/.body.XXXXXX")

  local re='^(BRIEF|WEISUNG|NACHFORDERUNG|GO|PING)_([A-Za-z0-9-]+)(\.fortsetzung)?(\.exec-(claude|codex))?(\.aufwand-(minimal|low|medium|high|xhigh))?(\.modell-([A-Za-z0-9._-]*[A-Za-z0-9]))?(\.n-([0-9a-f]{8}))?\.md$'
  reportname="REPORT_${base}_${ts}.md"

  local ok=0 m
  if [[ "$name" =~ $re ]]; then
    art="${BASH_REMATCH[1]}"; k="${BASH_REMATCH[2]}"
    fort="${BASH_REMATCH[3]}"; exec="${BASH_REMATCH[5]:-claude}"
    aufwand="${BASH_REMATCH[7]}"; model="${BASH_REMATCH[9]}"; nonce="${BASH_REMATCH[11]}"
    # Greedy-Modell schluckt ein folgendes ".n-<hex>" -> abspalten
    if [[ "$model" =~ ^(.*[A-Za-z0-9])\.n-([0-9a-f]{8})$ ]]; then
      model="${BASH_REMATCH[1]}"; nonce="${BASH_REMATCH[2]}"
    fi
    ok=1
    [[ "$model" =~ ^\.n-[0-9a-f]{8}$ ]] && ok=0   # ".modell-" ohne echte Modell-ID
    # Modell-IDs duerfen Punkte enthalten -> Marker anderer Segmente darin ablehnen (falsche Reihenfolge)
    m=".$model"
    [[ "$m" == *.fortsetzung* || "$m" == *.exec-* || "$m" == *.aufwand-* ]] && ok=0
  fi
  if [ "$ok" = 0 ]; then
    {
      echo "# REPORT $base"; echo
      echo "- Status: ABGELEHNT (Dateiname passt nicht zum Schema)"
      echo "- Brief: $name"; echo "- Run-ID: ${ts}_$name"; echo "- Zeit (UTC): $(utcl)"
    } > "$head"
    {
      echo "Erwartet: \`<ART>_<K>[.fortsetzung][.exec-<claude|codex>][.aufwand-<minimal|low|medium|high|xhigh>][.modell-<id>][.n-<8 hex>].md\` mit ART in BRIEF|WEISUNG|NACHFORDERUNG|GO|PING und K = [A-Za-z0-9-]+."
      echo "Reihenfolge: \`.fortsetzung\`, \`.exec-\`, \`.aufwand-\`, \`.modell-\` (immer zuletzt). Der Brief wurde nicht ausgefuehrt."
    } > "$body"
    # erst archivieren, dann Report veroeffentlichen (Importer sieht nie Report + Brief in eingang/)
    mv -f "$EIN/$name" "$ERL/${ts}_$name"
    write_report "$AUS/$reportname" "$head" "$body"
    printf '%s %s %s rc=%s dauer=%ss session=%s\n' "$(utcl)" "$name" "-" "REJECTED" 0 "-" >> "$LOGD/postbote.log"
    rm -f "$head" "$body"
    unclaim
    return 0
  fi

  run="${ts}_${base}"
  json="$LOGD/$run.json"; err="$LOGD/$run.stderr"
  local -a args=()
  start=$(utcl); t0=$(date +%s)
  local skip=""
  if [ -n "$fort" ]; then
    if [ -s "$STATE/$k.session" ]; then
      sid=$(head -n1 "$STATE/$k.session" | tr -d '[:space:]')
      # Sessions ohne .exec-Datei stammen aus v1 -> claude
      oldexec=$(head -n1 "$STATE/$k.exec" 2>/dev/null | tr -d '[:space:]'); oldexec="${oldexec:-claude}"
      if [ "$oldexec" != "$exec" ]; then
        rejected=1
        skip="Fortsetzung mit Executor '$exec' abgelehnt: die gespeicherte Session fuer '$k' gehoert zu '$oldexec' (state/$k.exec). Neuen Brief ohne .fortsetzung senden oder passenden .exec- waehlen."
      fi
    else
      skip="Fortsetzung angefordert, aber keine Session fuer Kuerzel '$k' in state/$k.session vorhanden."
    fi
  fi

  local bin
  if [ "$exec" = codex ]; then
    bin="$CODEX_BIN"
    if [ -n "$fort" ]; then args=(exec resume); else args=(exec); fi
    args+=(--json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox)
    [ -n "$model" ] && args+=(-m "$model")
    [ -n "$aufwand" ] && args+=(-c "model_reasoning_effort=$aufwand")
    [ -n "$fort" ] && args+=("$sid")
    args+=(-)
  else
    bin="$CLAUDE_BIN"
    args=(-p --output-format json --permission-mode "${FORGE_PERMISSION_MODE:-bypassPermissions}")
    [ -n "$model" ] && args+=(--model "$model")
    if [ -n "$aufwand" ]; then
      [ "$aufwand" = minimal ] && args+=(--effort low) || args+=(--effort "$aufwand")
    fi
    [ -n "$fort" ] && [ -z "$skip" ] && args+=(--resume "$sid")
  fi

  local newsid="" result="" cost="" usage=""
  if [ -n "$skip" ]; then
    unclaim
    rc=2; [ "$rejected" = 1 ] && rc=REJECTED
    : > "$json"; printf '%s\n' "$skip" > "$err"
    printf '%s\n' "FEHLER: $skip" > "$body"
  else
    ( forge_exec_env "$exec" "${ts}_$name" "${k%%-*}" "$k"; cd "$WORK" && exec timeout "${FORGE_MAX_SECONDS:-14400}" "$bin" "${args[@]}" < "$EIN/$name" > "$json" 2> "$err" 9>&- 8>&- ) &
    CHILD=$!
    unclaim      # Executor ist gestartet: Lock frei (forge-stop darf jetzt; der laufende Brief bleibt unberuehrt)
    hb_start
    wait "$CHILD"; rc=$?
    # wait kann durch Signal unterbrochen werden -> erneut auf Ende warten
    while kill -0 "$CHILD" 2>/dev/null; do wait "$CHILD"; rc=$?; done
    CHILD=""
    hb_stop
    if [ -s "$json" ]; then
      if [ "$exec" = codex ]; then
        newsid=$(codex_parse "$json" thread)
        result=$(codex_parse "$json" text)
        usage=$(codex_parse "$json" usage)
      else
        newsid=$(json_get "$json" session_id)
        result=$(json_get "$json" result)
        cost=$(json_get "$json" total_cost_usd)
        [ -z "$cost" ] && cost=$(json_get "$json" cost_usd)
      fi
    fi
    if [ -n "$result" ]; then
      printf '%s\n' "$result" > "$body"
    else
      {
        echo "FEHLER: keine auswertbare Antwort von $exec (rc=$rc)."
        if [ "$exec" = codex ]; then
          cerr=$(codex_parse "$json" error); [ -n "$cerr" ] && { echo; echo "Meldung: $cerr"; }
        fi
        echo; echo "stdout (Ende):"; echo '```'; tail -c 3000 "$json" 2>/dev/null; echo '```'
        echo; echo "stderr (Ende):"; echo '```'; tail -c 3000 "$err" 2>/dev/null; echo '```'
      } > "$body"
    fi
    if [ -n "$newsid" ]; then
      printf '%s\n' "$newsid" > "$STATE/$k.session"
      printf '%s\n' "$exec" > "$STATE/$k.exec"
    fi
  fi
  t1=$(date +%s); dur=$((t1 - t0)); end=$(utcl)
  [ "$rc" = 124 ] && echo "HINWEIS: Zeitlimit FORGE_MAX_SECONDS erreicht." >> "$body"

  {
    echo "# REPORT $base"; echo
    echo "- Brief: $name"
    echo "- Run-ID: ${ts}_$name"
    [ -n "$nonce" ] && echo "- Nonce: $nonce"
    echo "- Art / Kuerzel: $art / $k"
    echo "Executor: $exec"
    [ "$rejected" = 1 ] && echo "- Status: ABGELEHNT (Executor passt nicht zur gespeicherten Session)"
    [ -n "$aufwand" ] && echo "- Aufwand: $aufwand"
    echo "- Modell: ${model:-(Standard)}"
    if [ -n "$fort" ]; then echo "- Fortsetzung: ja (resume ${sid:-?})"; else echo "- Fortsetzung: nein"; fi
    echo "- Session: ${newsid:-${sid:--}}"
    echo "- Start (UTC): $start"
    echo "- Ende (UTC): $end"
    echo "- Dauer: ${dur}s"
    echo "- Exit-Code: $rc"
    [ -n "$cost" ] && echo "- cost_usd: $cost"
    [ -n "$usage" ] && echo "- usage (tokens): $usage"
    echo; echo "---"
  } > "$head"
  # erst archivieren, dann Report veroeffentlichen (Run-ID = Archivname erledigt/<ts>_<name>)
  mv -f "$EIN/$name" "$ERL/${ts}_$name"
  write_report "$AUS/$reportname" "$head" "$body"
  printf '%s %s %s rc=%s dauer=%ss session=%s\n' "$(utcl)" "$name" "${model:--}" "$rc" "$dur" "${newsid:-${sid:--}}" >> "$LOGD/postbote.log"
  rm -f "$head" "$body"
}

while :; do
  heartbeat
  [ "$STOP" = 1 ] && break
  # Neustart-Anforderung (bin/forge-request-restart.sh): nur hier, zwischen Runs, vor dem Claimen des naechsten Briefs
  if [ -e "$RESTART_FLAG" ]; then
    rid=$(sed -n 's/^requester=//p' "$RESTART_FLAG" 2>/dev/null | head -n1); rid="${rid:-unknown}"
    rm -f "$RESTART_FLAG"
    printf '%s RESTART requested by %s\n' "$(utcl)" "$rid" >> "$LOGD/postbote.log"
    exit 0   # systemd (Restart=always) startet neu
  fi
  # Kill-Switch: nichts Neues starten, solange STOP existiert (auch Symlink/Verzeichnis zaehlt)
  if [ -e "$STOP_FILE" ] || [ -L "$STOP_FILE" ]; then
    if [ "$PAUSED" = 0 ]; then printf '%s paused by STOP (%s)\n' "$(utcl)" "$STOP_FILE" >> "$LOGD/postbote.log"; PAUSED=1; fi
    [ "$ONCE" = 1 ] && break
    sleep "$POLL" 9>&- & wait $!
    continue
  fi
  if [ "$PAUSED" = 1 ]; then printf '%s resumed (STOP removed)\n' "$(utcl)" >> "$LOGD/postbote.log"; PAUSED=0; fi
  if name=$(next_brief); then
    if [ -n "${FORGE_HOOK_AFTER_SELECT:-}" ] && [ -x "$FORGE_HOOK_AFTER_SELECT" ]; then "$FORGE_HOOK_AFTER_SELECT" "$name" 9>&-; fi
    process "$name"; prc=$?
    if [ "$prc" = 71 ] || [ "$prc" = 72 ]; then   # STOP bzw. Lock-Problem im gesperrten Startabschnitt: nichts gestartet
      if [ "$PAUSED" = 0 ]; then
        if [ "$prc" = 71 ]; then printf '%s paused by STOP (%s)\n' "$(utcl)" "$STOP_FILE" >> "$LOGD/postbote.log"
        else printf '%s paused: dispatch lock unavailable (%s)\n' "$(utcl)" "$LOCK_FILE" >> "$LOGD/postbote.log"; fi
        PAUSED=1
      fi
      [ "$ONCE" = 1 ] && break
      sleep "$POLL" 9>&- & wait $!
      continue
    fi
    [ "$STOP" = 1 ] && break
    continue   # sofort naechsten pruefen
  fi
  [ "$ONCE" = 1 ] && break
  # unterbrechbares Schlafen
  sleep "$POLL" 9>&- & wait $!
done
exit 0
