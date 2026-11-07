# forge-lanes.sh - Lane-Bibliothek des Postboten (ADR-040, zweite Postfach-Lane). WIRD VON forge-postbote.sh GESOURCT, nicht direkt ausgefuehrt.
#
# Lane-Auswahl: FORGE_LANE (Standard 1; unterstuetzt: 1, 2). Lane 1 behaelt ALLE heutigen Pfade/Namen (eingang/, state/.lock, state/heartbeat, log/postbote.log,
#   state/restart-requested). Lane N>1 bekommt eigene: eingang-N/, state/.lock-laneN, state/heartbeat-laneN, log/postbote-laneN.log, state/restart-requested-laneN.
#   Roh-Logs je Run (log/<ts>_<base>.json|.stderr), erledigt/ und ausgang/ bleiben FLACH und gemeinsam (der forge-core-Importer globbt flach); Reports der Lane N>1 tragen "- Lane: N".
# Dateiname: optionales Segment `.lane-<N>` direkt vor `.n-<8 hex>` bzw. `.md`. Der Eingang entscheidet; liegt ein Brief mit fremdem Tag im Eingang, verschiebt der Watcher ihn
#   (nur wenn der Ziel-Eingang existiert; sonst bleibt alles wie heute: Dateiname passt nicht zum Schema => ABGELEHNT).
#
# Sperren (alle flock, Dateien unter state/locks/; geordnet erworben => kein Deadlock; gehalten vom Watcher-Prozess, im Kind/Heartbeat geschlossen):
#   1. all          S (geteilt) fuer jeden Lauf, X (exklusiv) fuer Laeufe mit unbekanntem Repo-Satz ("sperre alles")
#   2. deploy       X fuer jeden GO-Brief und die RUN-Jobs merge/deploy-stage (nie zwei GOs/Deploys gleichzeitig, lane-uebergreifend)
#   3. repo-<name>  X je Repo des Laufs (alphabetisch)
#   4. k-<K>        X je Kuerzel (state/<K>.session|exec werden nie von zwei Lanes gleichzeitig geschrieben)
#   Repo-Satz: Zeile `repos: a, b` (auch `Repos:`, `**Repos:**`, `> repos:`) in den ersten FORGE_LANE_HEAD_LINES (30) Zeilen des Briefs; `repos: none` = kein Repo; `repos: all` oder
#   fehlende/ungueltige/unbekannte Angabe (Name nicht in etc/lane-repos.list) = ALLE (sicherer Standard). RUN: args.repo aus dem JSON-Auftrag (unlesbar => ALLE).
#   Warten ist begrenzt (FORGE_LANE_LOCK_WAIT, Standard 18000 s > FORGE_MAX_SECONDS), geloggt ("LOCKWAIT ...") und haelt den Heartbeat am Leben; nach Ablauf bleibt der Brief
#   in eingang/ und wird erneut versucht (lautes Log, nie stilles Scheitern). Der Dispatch-Lock (control/.dispatch.lock) wird NIE waehrend des Wartens gehalten.

LANE="${FORGE_LANE:-1}"
case "$LANE" in 1|2) ;; *) echo "FEHLER: FORGE_LANE=$LANE nicht unterstuetzt (1 oder 2)" >&2; exit 2 ;; esac

# lane_paths: setzt EIN, LANE_LOCK_FILE, HBF, LOGF, RESTART_FLAG, LANE_SUF, LANE_LOCKS (benoetigt POST, STATE, LOGD)
lane_paths() {
  if [ "$LANE" = 1 ]; then
    LANE_SUF=""; EIN="$POST/eingang"; LANE_LOCK_FILE="$STATE/.lock"
  else
    LANE_SUF="-lane$LANE"; EIN="$POST/eingang-$LANE"; LANE_LOCK_FILE="$STATE/.lock$LANE_SUF"
  fi
  HBF="$STATE/heartbeat$LANE_SUF"
  HBTMP="$STATE/.heartbeat$LANE_SUF.tmp"
  RESTART_FLAG="$STATE/restart-requested$LANE_SUF"
  if [ "$LANE" = 1 ]; then LOGF="$LOGD/postbote.log"; else LOGF="$LOGD/postbote-lane$LANE.log"; fi
  LANE_LOCKS="$STATE/locks"
}
lane_inbox() { if [ "$1" = 1 ]; then printf '%s\n' "$POST/eingang"; else printf '%s\n' "$POST/eingang-$1"; fi; }

# ---- Routing ---------------------------------------------------------------------------------------------------------------------------------------
# lane_route: Briefe mit `.lane-<N>` fuer eine ANDERE Lane in deren Eingang verschieben (atomar, gleiche Partition; nur wenn der Ziel-Eingang existiert).
lane_route() {
  local f n t dst
  for f in "$EIN"/*.lane-[0-9]*; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    [[ "$n" =~ \.lane-([0-9]+)(\.n-[0-9a-f]{8})?\.md$ ]] || continue
    t="${BASH_REMATCH[1]}"
    case "$t" in 1|2) ;; *) continue ;; esac
    [ "$t" = "$LANE" ] && continue
    dst="$(lane_inbox "$t")"
    [ -d "$dst" ] || continue
    [ -e "$dst/$n" ] && continue
    if mv -n "$f" "$dst/$n" 2>/dev/null; then printf '%s ROUTED %s lane %s -> lane %s\n' "$(utcl)" "$n" "$LANE" "$t" >> "$LOGF"; fi
  done
}
# lane_canon <name>: Dateiname ohne das eigene `.lane-<LANE>`-Segment (fuer die Schema-Pruefung); fremde/unbekannte Tags bleiben stehen (=> ABGELEHNT wie heute)
lane_canon() {
  local n="$1"
  if [[ "$n" =~ ^(.+)\.lane-([0-9]+)((\.n-[0-9a-f]{8})?\.md)$ ]] && [ "${BASH_REMATCH[2]}" = "$LANE" ]; then
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\n' "$n"
  fi
}

# ---- Repo-Satz / Sperrplan --------------------------------------------------------------------------------------------------------------------------
LANE_REPOS_FILE="${FORGE_LANE_REPOS_FILE:-$BINDIR/../etc/lane-repos.list}"
lane_known_repo() { [ -r "$LANE_REPOS_FILE" ] && grep -qxF -- "$1" <(sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' "$LANE_REPOS_FILE"); }

# lane_parse_repos <datei>: gibt "ALL" oder "NONE" oder eine sortierte, einzeilige Repo-Liste aus
lane_parse_repos() {
  local f="$1" lines tok out="" found=0 line
  lines="$(head -n "${FORGE_LANE_HEAD_LINES:-30}" -- "$f" 2>/dev/null | head -c 8192 | tr -d '\r')"
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -nE 's/^[[:space:]>*_#-]*[Rr][Ee][Pp][Oo][Ss]?[*_]*[[:space:]]*:[*_]*[[:space:]]*(.*)$/\1/p')"
    [ -z "$line" ] && continue
    found=1
    line="${line//\`/}"; line="${line//\*/}"; line="${line//,/ }"
    for tok in $line; do
      tok="${tok,,}"; tok="${tok%/}"; tok="${tok##*/}"
      case "$tok" in all|'*') echo ALL; return 0 ;; none|-) continue ;; esac
      [[ "$tok" =~ ^[a-z0-9][a-z0-9_.-]{0,40}$ ]] || { echo ALL; return 0; }
      lane_known_repo "$tok" || { echo ALL; return 0; }
      out+="$tok"$'\n'
    done
  done < <(printf '%s\n' "$lines" | grep -E '^[[:space:]>*_#-]*[Rr][Ee][Pp][Oo][Ss]?[*_]*[[:space:]]*:')
  [ "$found" = 0 ] && { echo ALL; return 0; }
  out="$(printf '%s' "$out" | sort -u | tr '\n' ' ')"; out="${out% }"
  [ -z "$out" ] && echo NONE || echo "$out"
}

# lane_plan <name>: setzt PLAN_LOCKS (Array "S:all" "X:deploy" "X:repo-x" "X:k-K" in Erwerbsreihenfolge) und PLAN_DESC. Namen, die das Schema nicht erfuellen (=> ABGELEHNT), brauchen keine Sperren.
lane_plan() {
  local name cname="$1" art k repos deploy=0 r spec
  cname="$(lane_canon "$1")"; name="$1"
  PLAN_LOCKS=(); PLAN_DESC=""
  [[ "$cname" =~ ^(BRIEF|WEISUNG|NACHFORDERUNG|GO|PING|RUN)_([A-Za-z0-9-]+)(\.|$) ]] || return 0
  art="${BASH_REMATCH[1]}"; k="${BASH_REMATCH[2]}"
  if [ "$art" = RUN ]; then
    spec="$(python3 -I - "$EIN/$name" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    job = d["job"]; repo = d["args"]["repo"]
    assert isinstance(job, str) and isinstance(repo, str)
    print(job, repo)
except Exception:
    print("? ALL")
PY
)"
    [ -z "$spec" ] && spec="? ALL"
    case "${spec%% *}" in merge|deploy-stage) deploy=1 ;; esac
    r="${spec#* }"
    if [ "$r" = ALL ] || ! lane_known_repo "$r"; then repos=ALL; else repos="$r"; fi
    [ "${spec%% *}" = "?" ] && deploy=1   # unlesbarer Auftrag: wie GO behandeln (sicherer Standard)
  else
    repos="$(lane_parse_repos "$EIN/$name")"
    [ "$art" = GO ] && deploy=1
  fi
  if [ "$repos" = ALL ]; then PLAN_LOCKS+=("X:all"); else PLAN_LOCKS+=("S:all"); fi
  [ "$deploy" = 1 ] && PLAN_LOCKS+=("X:deploy")
  if [ "$repos" != ALL ] && [ "$repos" != NONE ]; then for r in $repos; do PLAN_LOCKS+=("X:repo-$r"); done; fi
  [ "$art" != RUN ] && PLAN_LOCKS+=("X:k-$k")
  PLAN_DESC="art=$art repos=$repos deploy=$deploy"
}

# ---- Erwerb / Freigabe --------------------------------------------------------------------------------------------------------------------------------
LANEFDS=(); LANE_HELD=()
lane_close_fds() { local fd; for fd in "${LANEFDS[@]}"; do exec {fd}>&-; done; }   # im Kind/Heartbeat-Subshell: haelt keine Sperre ueber die Lebenszeit des Watchers hinaus
lane_release() {
  local fd h
  for h in "${LANE_HELD[@]}"; do rm -f "$LANE_LOCKS/holders/${h#*:}" 2>/dev/null; done
  for fd in "${LANEFDS[@]}"; do exec {fd}>&-; done
  LANEFDS=(); LANE_HELD=()
}
lane_sleep() { ( lane_close_fds; exec sleep "$1" ) >/dev/null 2>&1 9>&- & wait $!; }

# lane_acquire_one <S|X:lock> <brief>: 0 erworben | 1 Zeit abgelaufen | 3 Abbruch (SIGTERM). Loggt Warten, Dauer und Halter.
lane_acquire_one() {
  local spec="$1" brief="$2" mode="${1%%:*}" lock="${1#*:}" fd opt=-x t0 now waited=0 last=0 holder dl
  [ "$mode" = S ] && opt=-s
  { exec {fd}>>"$LANE_LOCKS/$lock"; } 2>/dev/null || { printf '%s LOCKWAIT lane=%s brief=%s lock=%s UNAVAILABLE (cannot open)\n' "$(utcl)" "$LANE" "$brief" "$lock" >> "$LOGF"; return 1; }
  if flock -n $opt "$fd" 2>/dev/null; then LANEFDS+=("$fd"); LANE_HELD+=("$spec"); lane_holder "$lock" "$brief" "$mode"; return 0; fi
  t0=$(date +%s); dl="${FORGE_LANE_LOCK_WAIT:-18000}"
  holder="$(cat "$LANE_LOCKS/holders/$lock" 2>/dev/null | head -n1)"
  printf '%s LOCKWAIT lane=%s brief=%s lock=%s mode=%s waiting (max %ss) held-by: %s\n' "$(utcl)" "$LANE" "$brief" "$lock" "$mode" "$dl" "${holder:-unknown}" >> "$LOGF"
  while :; do
    heartbeat
    if [ "${STOP:-0}" = 1 ]; then exec {fd}>&-; printf '%s LOCKWAIT lane=%s brief=%s lock=%s aborted (shutdown)\n' "$(utcl)" "$LANE" "$brief" "$lock" >> "$LOGF"; return 3; fi
    if flock -n $opt "$fd" 2>/dev/null; then
      now=$(date +%s)
      printf '%s LOCKWAIT lane=%s brief=%s lock=%s acquired after %ss\n' "$(utcl)" "$LANE" "$brief" "$lock" "$((now - t0))" >> "$LOGF"
      LANEFDS+=("$fd"); LANE_HELD+=("$spec"); lane_holder "$lock" "$brief" "$mode"; return 0
    fi
    now=$(date +%s); waited=$((now - t0))
    if [ "$waited" -ge "$dl" ]; then
      exec {fd}>&-
      printf '%s LOCKWAIT lane=%s brief=%s lock=%s TIMEOUT after %ss - brief stays in eingang, retry follows\n' "$(utcl)" "$LANE" "$brief" "$lock" "$waited" >> "$LOGF"
      return 1
    fi
    if [ $((waited - last)) -ge "${FORGE_LANE_LOCK_LOG:-900}" ]; then
      last=$waited; holder="$(cat "$LANE_LOCKS/holders/$lock" 2>/dev/null | head -n1)"
      printf '%s LOCKWAIT lane=%s brief=%s lock=%s still waiting %ss held-by: %s\n' "$(utcl)" "$LANE" "$brief" "$lock" "$waited" "${holder:-unknown}" >> "$LOGF"
    fi
    lane_sleep "${FORGE_LANE_LOCK_POLL:-2}"
  done
}
lane_holder() {   # nur Auskunft (Log beim Warten); der Halter ist die flock-Beschreibung, nicht diese Datei
  [ "$2" = "" ] && return 0
  [ "$3" = X ] && printf 'lane=%s brief=%s since=%s pid=%s\n' "$LANE" "$2" "$(utcl)" "$$" > "$LANE_LOCKS/holders/$1" 2>/dev/null
  return 0
}

# ---- Aktivierung: Lane 1 sperrt/markiert NUR, wenn eingang-2/ existiert (ohne Lane 2 ist Lane 1 Byte fuer Byte wie vorher: kein locks/-Verzeichnis, keine Marker) -------------------
LANE_PEER_WARNED=0
lane_two_enabled() { [ -d "$(lane_inbox 2)" ]; }
# lane_arm: Lane 1, ZWISCHEN den Laeufen (Schleifenkopf): sieht sie eingang-2/, schreibt sie state/lane1-armed (= ihre PID; erneut, falls die Datei fehlt oder eine fremde PID traegt).
# Ab dem naechsten Brief nimmt sie Sperren. Ohne eingang-2/ tut diese Funktion nichts (Lane 1 bleibt unveraendert).
lane_arm() {
  local cur=""
  [ "$LANE" = 1 ] && lane_two_enabled || return 0
  read -r cur < "$STATE/lane1-armed" 2>/dev/null
  [ "$cur" = "$$" ] && return 0
  printf '%s\n' "$$" > "$STATE/.lane1-armed.tmp" && mv -f "$STATE/.lane1-armed.tmp" "$STATE/lane1-armed" || return 0
  printf '%s lane 1 armed (eingang-2 present): repo/deploy locks active from the next brief on\n' "$(utcl)" >> "$LOGF"
  return 0
}
# lane1_running: haelt irgendein Prozess den flock von state/.lock (Lane 1)? Liest /proc/locks (Inode-Vergleich) statt selbst zu locken - ein Probe-flock koennte den Start von Lane 1 stoeren
# ("laeuft bereits"). Nicht lesbar/Inode unbekannt => "laeuft" (sicherer Standard).
lane1_running() {
  local ino
  ino="$(stat -c %i "$STATE/.lock" 2>/dev/null)" || return 1          # keine Lock-Datei: Lane 1 lief noch nie
  [ -r /proc/locks ] || return 0
  awk -v i="$ino" '$2 == "FLOCK" && $6 ~ (":" i "$") { f = 1 } END { exit !f }' /proc/locks 2>/dev/null
}
# lane_peer_ok (nur Lane >= 2): Lane 1 haelt entweder nichts (kein Prozess, flock frei) oder hat sich zwischen zwei Laeufen "armed" (PID lebt). Sonst koennte ein Lauf von Lane 1, der VOR der
# Aktivierung ohne Sperren startete, mit einem Lauf dieser Lane kollidieren => bis dahin startet diese Lane nichts (geloggt, Heartbeat laeuft).
lane_peer_ok() {
  local pid=""
  [ "$LANE" = 1 ] && return 0
  if ! lane1_running; then LANE_PEER_WARNED=0; return 0; fi
  read -r pid < "$STATE/lane1-armed" 2>/dev/null
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then LANE_PEER_WARNED=0; return 0; fi
  if [ "$LANE_PEER_WARNED" = 0 ]; then
    printf '%s PEER lane=%s waiting: lane 1 is running but has not armed its locks (old watcher code or run in flight since before eingang-2 existed); nothing is started here until it does\n' "$(utcl)" "$LANE" >> "$LOGF"
    LANE_PEER_WARNED=1
  fi
  return 1
}

# lane_lock_for <name>: Sperrplan bilden und in Reihenfolge erwerben. 0 = alles erworben (oder nichts noetig) | 1 = Zeit abgelaufen (nichts gehalten) | 3 = Abbruch
lane_lock_for() {
  local name="$1" s rc
  [ "$LANE" = 1 ] && ! lane_two_enabled && return 0   # Lane 1 ohne Lane 2: keine Sperren (unveraendertes Verhalten)
  lane_plan "$name"
  [ "${#PLAN_LOCKS[@]}" -gt 0 ] || return 0
  mkdir -p "$LANE_LOCKS/holders" 2>/dev/null
  if [ ! -d "$LANE_LOCKS/holders" ]; then printf '%s LOCKWAIT lane=%s brief=%s locks UNAVAILABLE (%s) - brief stays in eingang\n' "$(utcl)" "$LANE" "$name" "$LANE_LOCKS" >> "$LOGF"; return 1; fi
  for s in "${PLAN_LOCKS[@]}"; do
    lane_acquire_one "$s" "$name"; rc=$?
    if [ "$rc" != 0 ]; then lane_release; return "$rc"; fi
  done
  return 0
}
