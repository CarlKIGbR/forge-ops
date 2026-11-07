#!/usr/bin/env bash
# Innenteil des Container-Trockenlaufs (tests/lanes_dryrun_container.sh): zwei Watcher (Lane 1/2) mit zwei Schein-Auftraegen (Stub-claude) im Wegwerf-Postfach; Zeitleiste + Urteil.
# Laeuft NUR im Wegwerf-Container (oder lokal mit gesetztem OPSBIN); /srv/forge/post wird nie beruehrt.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OPSBIN="${OPSBIN:-$HERE/../bin}"
T=$(mktemp -d); trap 'cleanup_lanes; rm -rf "$T"' EXIT
# shellcheck source=/dev/null
. "$HERE/lib_lanes.sh"
make_stub
timeline() {   # Zeitleiste relativ zum ersten START
  python3 -I - "$STUB_LOG" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
t0 = min(float(r[0]) for r in rows)
for r in sorted(rows, key=lambda r: float(r[0])):
    print("    t+%5.1fs  %-5s %-8s lane %s" % (float(r[0]) - t0, r[1], r[2], r[3]))
PY
}
scenario() {   # name repoA repoB gokind(A,B: GO|BRIEF) erwartet(overlap|serial)
  local n="$1" ra="$2" rb="$3" ka="$4" kb="$5" want="$6"
  new_world "$n"; mkdir -p "$POST/eingang-2"
  start_lane 1; start_lane 2; wait_for 10 test -e "$POST/state/lane1-armed"
  brief 1 "${ka}_dry${n}a.md" "${n}a" 4 "repos: $ra"; wait_for 15 started "${n}a"
  brief 2 "${kb}_dry${n}b.md" "${n}b" 2 "repos: $rb"; wait_for 40 ended "${n}b"; wait_for 20 ended "${n}a"
  echo "  $n: Lane 1 $ka repos=$ra (4 s)  |  Lane 2 $kb repos=$rb (2 s)  => erwartet: $want"; timeline
  if [ "$want" = overlap ]; then check "$n: Laeufe ueberschneiden sich" overlap "${n}a" "${n}b"; else check "$n: Laeufe nacheinander" after "${n}a" "${n}b"; fi
  stop_lane 1; stop_lane 2
}
echo "# Trockenlauf: zwei Schein-Auftraege in zwei Lanes (kein Netz, kein echtes claude)"
scenario s1 forge-core forge-ops BRIEF BRIEF overlap
scenario s2 forge-core forge-core BRIEF BRIEF serial
scenario s3 forge-core forge-ops GO GO serial
scenario s4 forge-core forge-ops GO BRIEF overlap
echo; echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
