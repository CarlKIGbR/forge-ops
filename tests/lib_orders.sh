# Gemeinsame Hilfen der forge-ops-Shelltests fuer den Dispatch-Eintrag (ADR-028): bildet core.graph_run_orders durch tests/fake-psql nach (nur die Verbrauchs-Semantik).
# Voraussetzung: $T (Temp-Verzeichnis), $POST, $OPS gesetzt. Der Eintrag entsteht in der Praxis im Graph-Dispatch-Pfad; die Tests legen ihn gezielt an (oder lassen ihn mit NO_AUTO_ORDER=1 weg).
ORDERS="$T/orders"; : > "$ORDERS"
export FORGE_RUN_ORDER_PSQL="[\"python3\",\"$OPS/tests/fake-psql\",\"--state\",\"$ORDERS\"]"
# order_file <datei> [zustand]: Eintrag fuer eine RUN-Datei (Nonce aus dem Namen, sha256 der Bytes, graph_run_id aus dem JSON); idempotent je Nonce+sha
order_file() {
  python3 - "$1" "${2:-published}" "$ORDERS" <<'PY'
import hashlib, json, re, sys
p, state, orders = sys.argv[1:4]
data = open(p, "rb").read()
m = re.search(r"\.n-([0-9a-f]{8})\.md$", p)
try:
    gid = json.loads(data)["graph_run_id"]
except Exception:
    sys.exit(0)
if not m or not isinstance(gid, int) or isinstance(gid, bool):
    sys.exit(0)
sha = hashlib.sha256(data).hexdigest()
if any(ln.split()[:2] == [m.group(1), sha] for ln in open(orders).read().splitlines() if ln.strip()):
    sys.exit(0)
with open(orders, "a") as f:
    f.write(f"{m.group(1)} {sha} {gid} {state}\n")
PY
}
autoorder() {
  [ -n "${NO_AUTO_ORDER:-}" ] && return 0
  local f
  for f in "$POST"/eingang/RUN_*.md; do [ -e "$f" ] && order_file "$f"; done
  return 0
}
