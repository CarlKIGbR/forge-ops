#!/usr/bin/env bash
# forge-postbote.sh - Postbote (Watcher) fuer das forge-post Postfach.
# Laeuft als User "forge". Nimmt Briefe aus eingang/, ruft "claude -p" auf,
# schreibt Reports nach ausgang/. Strikt sequentiell (flock), Poll alle 5 s.
#
# Dateiname: <ART>_<K>[.fortsetzung][.modell-<id>].md
#   ART = BRIEF|WEISUNG|NACHFORDERUNG|GO|PING ; K = [A-Za-z0-9-]+
#
# Umgebung: FORGE_BASE (Default /srv/forge), FORGE_MAX_SECONDS (14400),
#           FORGE_PERMISSION_MODE (bypassPermissions), FORGE_POLL (5),
#           FORGE_MIN_AGE (3), CLAUDE_BIN (claude)
# Flags: --once  (eine Runde: alle faelligen Briefe abarbeiten, dann Ende)
set -u

BASE="${FORGE_BASE:-/srv/forge}"
POST="$BASE/post"
WORK="$BASE/work"
POLL="${FORGE_POLL:-5}"
MIN_AGE="${FORGE_MIN_AGE:-3}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

umask 0002
export PATH="${HOME:-/srv/forge/home}/.local/bin:$PATH"

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
CHILD=""
# shellcheck disable=SC2329
on_term() {
  STOP=1
  # laufenden Auftrag sauber beenden, nichts Neues beginnen
  [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
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

# write_report <ziel> <kopf-datei> <body-datei>   (atomar: .teil -> mv)
write_report() {
  local dst="$1" head="$2" body="$3"
  { cat "$head"; echo; cat "$body"; } > "$dst.teil" && mv -f "$dst.teil" "$dst"
}

heartbeat() {
  utcl > "$STATE/.heartbeat.tmp" && mv -f "$STATE/.heartbeat.tmp" "$STATE/heartbeat"
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

process() {
  local name="$1" base art k fort model sid="" start end t0 t1 dur rc=0
  local ts run json err head body cost reportname
  base="${name%.md}"
  ts=$(utc)
  head=$(mktemp "$STATE/.head.XXXXXX"); body=$(mktemp "$STATE/.body.XXXXXX")

  local re='^(BRIEF|WEISUNG|NACHFORDERUNG|GO|PING)_([A-Za-z0-9-]+)(\.fortsetzung)?(\.modell-([A-Za-z0-9._-]*[A-Za-z0-9]))?\.md$'
  reportname="REPORT_${base}_${ts}.md"

  if ! [[ "$name" =~ $re ]] || [[ "${BASH_REMATCH[5]}" == *fortsetzung* ]]; then
    {
      echo "# REPORT $base"; echo
      echo "- Status: ABGELEHNT (Dateiname passt nicht zum Schema)"
      echo "- Brief: $name"; echo "- Zeit (UTC): $(utcl)"
    } > "$head"
    {
      echo "Erwartet: \`<ART>_<K>[.fortsetzung][.modell-<id>].md\` mit ART in BRIEF|WEISUNG|NACHFORDERUNG|GO|PING und K = [A-Za-z0-9-]+."
      echo "Reihenfolge: \`.fortsetzung\` vor \`.modell-\`. Der Brief wurde nicht ausgefuehrt."
    } > "$body"
    write_report "$AUS/$reportname" "$head" "$body"
    mv -f "$EIN/$name" "$ERL/${ts}_$name"
    printf '%s %s %s rc=%s dauer=%ss session=%s\n' "$(utcl)" "$name" "-" "REJECTED" 0 "-" >> "$LOGD/postbote.log"
    rm -f "$head" "$body"
    return 0
  fi
  art="${BASH_REMATCH[1]}"; k="${BASH_REMATCH[2]}"
  fort="${BASH_REMATCH[3]}"; model="${BASH_REMATCH[5]}"

  run="${ts}_${base}"
  json="$LOGD/$run.json"; err="$LOGD/$run.stderr"
  local -a args=(-p --output-format json --permission-mode "${FORGE_PERMISSION_MODE:-bypassPermissions}")
  [ -n "$model" ] && args+=(--model "$model")

  start=$(utcl); t0=$(date +%s)
  local skip=""
  if [ -n "$fort" ]; then
    if [ -s "$STATE/$k.session" ]; then
      sid=$(head -n1 "$STATE/$k.session" | tr -d '[:space:]')
      args+=(--resume "$sid")
    else
      skip="Fortsetzung angefordert, aber keine Session fuer Kuerzel '$k' in state/$k.session vorhanden."
    fi
  fi

  local newsid="" result="" cost=""
  if [ -n "$skip" ]; then
    rc=2
    : > "$json"; printf '%s\n' "$skip" > "$err"
    printf '%s\n' "FEHLER: $skip" > "$body"
  else
    ( cd "$WORK" && exec timeout "${FORGE_MAX_SECONDS:-14400}" "$CLAUDE_BIN" "${args[@]}" < "$EIN/$name" > "$json" 2> "$err" 9>&- ) &
    CHILD=$!
    wait "$CHILD"; rc=$?
    # wait kann durch Signal unterbrochen werden -> erneut auf Ende warten
    while kill -0 "$CHILD" 2>/dev/null; do wait "$CHILD"; rc=$?; done
    CHILD=""
    if [ -s "$json" ]; then
      newsid=$(json_get "$json" session_id)
      result=$(json_get "$json" result)
      cost=$(json_get "$json" total_cost_usd)
      [ -z "$cost" ] && cost=$(json_get "$json" cost_usd)
    fi
    if [ -n "$result" ]; then
      printf '%s\n' "$result" > "$body"
    else
      {
        echo "FEHLER: keine auswertbare Antwort von claude (rc=$rc)."
        echo; echo "stdout (Ende):"; echo '```'; tail -c 3000 "$json" 2>/dev/null; echo '```'
        echo; echo "stderr (Ende):"; echo '```'; tail -c 3000 "$err" 2>/dev/null; echo '```'
      } > "$body"
    fi
    [ -n "$newsid" ] && printf '%s\n' "$newsid" > "$STATE/$k.session"
  fi
  t1=$(date +%s); dur=$((t1 - t0)); end=$(utcl)
  [ "$rc" = 124 ] && echo "HINWEIS: Zeitlimit FORGE_MAX_SECONDS erreicht." >> "$body"

  {
    echo "# REPORT $base"; echo
    echo "- Brief: $name"
    echo "- Art / Kuerzel: $art / $k"
    echo "- Modell: ${model:-(Standard)}"
    if [ -n "$fort" ]; then echo "- Fortsetzung: ja (resume ${sid:-?})"; else echo "- Fortsetzung: nein"; fi
    echo "- Session: ${newsid:-${sid:--}}"
    echo "- Start (UTC): $start"
    echo "- Ende (UTC): $end"
    echo "- Dauer: ${dur}s"
    echo "- Exit-Code: $rc"
    [ -n "$cost" ] && echo "- cost_usd: $cost"
    echo; echo "---"
  } > "$head"
  write_report "$AUS/$reportname" "$head" "$body"
  mv -f "$EIN/$name" "$ERL/${ts}_$name"
  printf '%s %s %s rc=%s dauer=%ss session=%s\n' "$(utcl)" "$name" "${model:--}" "$rc" "$dur" "${newsid:-${sid:--}}" >> "$LOGD/postbote.log"
  rm -f "$head" "$body"
}

while :; do
  heartbeat
  [ "$STOP" = 1 ] && break
  if name=$(next_brief); then
    process "$name"
    [ "$STOP" = 1 ] && break
    continue   # sofort naechsten pruefen
  fi
  [ "$ONCE" = 1 ] && break
  # unterbrechbares Schlafen
  sleep "$POLL" 9>&- & wait $!
done
exit 0
