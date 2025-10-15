#!/usr/bin/env bash
set -euo pipefail
# usage: run_remote.sh <container_name> <image> <host_port>
NAME="$1"; IMAGE="$2"; PORT="$3"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker pull "$IMAGE"
docker run -d --name "$NAME" -p ${PORT}:8080 "$IMAGE"
echo "running $NAME on :$PORT with $IMAGE"