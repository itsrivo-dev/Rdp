#!/usr/bin/env bash
# Build the Ubuntu Cloud PC image locally (same image Railway builds).
set -Eeuo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cloudpc:test}"
echo "building ${IMAGE} ..."
docker build --progress=plain -t "${IMAGE}" .
docker image inspect "${IMAGE}" --format 'built {{.RepoTags}}  size {{.Size}} bytes'
