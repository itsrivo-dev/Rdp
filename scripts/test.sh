#!/usr/bin/env bash
# Build the image and run the full test suite (static checks + container tests).
#
#   scripts/test.sh            build + lint + integration
#   scripts/test.sh --no-build use the existing image
#
# Needs docker. For the real RDP login tests also install:
#   sudo apt-get install -y freerdp2-x11 xvfb jq
set -Eeuo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cloudpc:test}"
BUILD=true
[ "${1:-}" = "--no-build" ] && BUILD=false

echo "###############################################################"
echo "# static checks"
echo "###############################################################"
tests/lint.sh

if [ "${BUILD}" = true ]; then
    echo
    echo "###############################################################"
    echo "# docker build"
    echo "###############################################################"
    IMAGE="${IMAGE}" scripts/build.sh
fi

echo
echo "###############################################################"
echo "# integration tests"
echo "###############################################################"
tests/integration.sh "${IMAGE}"
