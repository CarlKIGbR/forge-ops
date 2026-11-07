#!/usr/bin/env bash
# Container-Trockenlauf der zweiten Lane (ADR-040): startet ein Wegwerf-Container (--rm, ohne Netz, schreibgeschuetztes Wurzel-Dateisystem, nur tmpfs beschreibbar, dieses Repo read-only gemountet)
# und fuehrt darin tests/lanes_dryrun_inner.sh aus. Beruehrt weder /srv/forge/post noch ein laufendes Unit.
# Aufruf: tests/lanes_dryrun_container.sh   (Exit 0 = alle Szenarien wie erwartet).  Image: LANE_DRYRUN_IMAGE (Standard forge-node/owner-guide-dryrun:local; braucht bash, flock, python3).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; OPS="$(cd "$HERE/.." && pwd)"
IMG="${LANE_DRYRUN_IMAGE:-forge-node/owner-guide-dryrun:local}"
command -v docker >/dev/null || { echo "ENV: docker fehlt"; exit 3; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "ENV: Image $IMG fehlt (LANE_DRYRUN_IMAGE setzen)"; exit 3; }
exec docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=64m --cap-drop ALL --security-opt no-new-privileges \
  --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$OPS:/ops:ro" -w /tmp --entrypoint bash "$IMG" /ops/tests/lanes_dryrun_inner.sh
