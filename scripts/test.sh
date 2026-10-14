#!/usr/bin/env bash
# =============================================================================
#  Full local test run: static checks, unit tests, image build, end-to-end.
#
#     scripts/test.sh              everything
#     scripts/test.sh --no-build   reuse an existing image (default cloudpc:test)
#     scripts/test.sh --fast       static checks + unit tests only
#
#  Needs Docker. For the real desktop tests install the client side:
#     pip install websocket-client pycryptodome Pillow
#  (without them those checks are skipped with a NOTE, everything else runs)
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cloudpc:test}"
BUILD=true
FAST=false
for arg in "$@"; do
    case "${arg}" in
        --no-build) BUILD=false ;;
        --fast)     FAST=true; BUILD=false ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

banner() { printf '\n\033[1;34m###############################################################\n# %s\n###############################################################\033[0m\n' "$*"; }

banner "static checks"
tests/lint.sh

banner "unit tests"
python3 -m unittest discover -s tests/unit -v

if [ "${FAST}" = true ]; then
    echo
    echo "fast mode: stopping before the Docker build"
    exit 0
fi

if [ "${BUILD}" = true ]; then
    banner "docker build"
    IMAGE="${IMAGE}" scripts/build.sh
fi

banner "end-to-end tests"
tests/integration.sh "${IMAGE}"
