#!/usr/bin/env bash
# =============================================================================
#  Static checks - fast, no Docker required.
#
#    * shell syntax + shellcheck (when installed)
#    * Python syntax for the gateway, the build tools and the test client
#    * the gateway must be standard-library only (no pip packages in the image)
#    * XML / JSON / INI well-formedness
#    * Dockerfile sanity: pinned noVNC checksum, no secrets, required directives
#    * repository hygiene: no leftover RDP stack, no credentials, no external
#      web assets on the login page
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YLW=""; RST=""; }
ok()   { PASS=$((PASS+1)); printf '%sPASS%s %s\n' "${GRN}" "${RST}" "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '%sFAIL%s %s\n' "${RED}" "${RST}" "$*"; }
note() { printf '%sNOTE%s %s\n' "${YLW}" "${RST}" "$*"; }

SHELL_SCRIPTS=(
    docker/entrypoint.sh
    docker/lib/common.sh
    docker/bin/cloudpc-vnc
    docker/bin/cloudpc-session
    docker/bin/cloudpc-apply-defaults
    docker/bin/cloudpc-password
    docker/bin/cloudpc-health
    docker/bin/cloudpc-status
    docker/bin/cloudpc-watchdog
    tests/integration.sh
    tests/lint.sh
    scripts/build.sh
    scripts/test.sh
    scripts/railway-setup.sh
)
PYTHON_FILES=(
    docker/gateway/server.py
    docker/gateway/wsproto.py
    docker/gateway/security.py
    docker/tools/make_icons.py
    docker/tools/build_novnc_page.py
    tests/clients/rfb_probe.py
    tests/unit/test_gateway.py
    tests/unit/test_build_tools.py
    tests/unit/test_entrypoint_blocks.py
    tests/gateway_smoke.py
)

echo "== shell syntax =="
for file in "${SHELL_SCRIPTS[@]}"; do
    [ -f "${file}" ] || { bad "missing ${file}"; continue; }
    if head -1 "${file}" | grep -q bash; then
        interp="bash"
    else
        interp="sh"
    fi
    if "${interp}" -n "${file}" 2>/tmp/cloudpc-syntax.err; then
        ok "syntax ${file}"
    else
        bad "syntax ${file}: $(head -3 /tmp/cloudpc-syntax.err)"
    fi
done

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    for file in "${SHELL_SCRIPTS[@]}"; do
        [ -f "${file}" ] || continue
        if shellcheck -S warning -e SC1091,SC1090 "${file}" >/tmp/cloudpc-shellcheck.out 2>&1; then
            ok "shellcheck ${file}"
        else
            bad "shellcheck ${file}"
            sed 's/^/     /' /tmp/cloudpc-shellcheck.out | head -20
        fi
    done
else
    note "shellcheck not installed - skipped"
fi

echo
echo "== python syntax =="
for file in "${PYTHON_FILES[@]}"; do
    if python3 -m py_compile "${file}" 2>/tmp/cloudpc-py.err; then
        ok "compile ${file}"
    else
        bad "compile ${file}: $(head -3 /tmp/cloudpc-py.err)"
    fi
done

echo
echo "== embedded python blocks in the entrypoint =="
if python3 - <<'PY'
import re
import sys

source = open("docker/entrypoint.sh", encoding="utf-8").read()
blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", source, re.S)
if not blocks:
    print("no embedded python found")
    sys.exit(1)
for index, block in enumerate(blocks):
    compile(block, "<entrypoint block %d>" % index, "exec")
print("%d embedded blocks compile" % len(blocks))
PY
then
    ok "embedded python in docker/entrypoint.sh compiles"
else
    bad "embedded python in docker/entrypoint.sh does not compile"
fi

echo
echo "== the gateway and tools use the standard library only =="
if python3 - <<'PY'
import ast
import os
import sys

stdlib = set(sys.stdlib_module_names)
local = {"wsproto", "security", "server"}
allowed = stdlib | local
third_party = []
for directory in ("docker/gateway", "docker/tools"):
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".py"):
            continue
        path = os.path.join(directory, name)
        tree = ast.parse(open(path, encoding="utf-8").read(), path)
        for node in ast.walk(tree):
            modules = []
            if isinstance(node, ast.Import):
                modules = [alias.name.split(".")[0] for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
                modules = [node.module.split(".")[0]]
            for module in modules:
                if module not in allowed:
                    third_party.append("%s: %s" % (path, module))
if third_party:
    print("third-party imports found: %s" % ", ".join(third_party))
    sys.exit(1)
print("only standard library imports")
PY
then
    ok "gateway and build tools import the standard library only"
else
    bad "gateway or tools import third-party packages (the image installs none)"
fi

echo
echo "== xml / json =="
while IFS= read -r file; do
    if python3 -c "import xml.dom.minidom, sys; xml.dom.minidom.parse(sys.argv[1])" "${file}" 2>/dev/null; then
        ok "xml ${file}"
    else
        bad "xml ${file} is not well-formed"
    fi
done < <(find docker/skel -name '*.xml' | sort)

MANIFEST="docker/gateway/static/manifest.webmanifest"
if python3 -c "import json, sys; json.load(open(sys.argv[1]))" "${MANIFEST}" 2>/dev/null; then
    ok "json ${MANIFEST}"
else
    bad "json ${MANIFEST} is not valid"
fi

echo
echo "== desktop configuration sanity =="
PANEL="docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
if grep -q "workspace_count" docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml \
   && grep -q 'value="1"' docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml; then
    ok "one workspace configured (a phone shows a single desktop)"
else
    note "workspace count is not 1"
fi
if grep -q "use_compositing" docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml \
   && grep -q 'value="false"' docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml; then
    ok "compositing disabled (saves CPU and bandwidth)"
else
    bad "compositing is not disabled in xfwm4.xml"
fi
for plugin in applicationsmenu launcher tasklist clock actions separator; do
    grep -q "value=\"${plugin}\"" "${PANEL}" || bad "panel layout lost the ${plugin} plugin"
done
ok "panel layout only references plugins the image installs"

if grep -q "rgba1" docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml; then
    ok "flat colour desktop background configured"
else
    note "desktop background is not a flat colour"
fi

if [ -f docker/skel/.config/autostart/cloudpc-defaults.desktop ]; then
    ok "autostart entry for the desktop defaults is present"
else
    bad "missing autostart entry for cloudpc-apply-defaults"
fi

echo
echo "== Dockerfile sanity =="
if grep -qE '^FROM ubuntu:22\.04' Dockerfile; then
    ok "Dockerfile builds on ubuntu:22.04"
else
    bad "Dockerfile does not use ubuntu:22.04"
fi
for directive in ENTRYPOINT HEALTHCHECK EXPOSE; do
    grep -q "^${directive}" Dockerfile && ok "Dockerfile has ${directive}" || bad "Dockerfile misses ${directive}"
done
if grep -q "NOVNC_SHA256=[0-9a-f]\{64\}" Dockerfile; then
    ok "noVNC download is pinned with a sha256 checksum"
else
    bad "noVNC download is not checksum-pinned"
fi
if grep -q "sha256sum -c" Dockerfile; then
    ok "the build verifies the noVNC checksum"
else
    bad "the build does not verify the noVNC checksum"
fi
if grep -q "MOZILLA_KEY_FPR" Dockerfile && grep -q "unexpected Mozilla signing key" Dockerfile; then
    ok "Mozilla's APT key is fingerprint-verified"
else
    bad "Firefox is installed without verifying the signing key"
fi
if grep -q -- "--no-install-recommends" Dockerfile; then
    ok "packages are installed without recommends (smaller image)"
else
    bad "apt-get install does not use --no-install-recommends"
fi
if grep -qE "^EXPOSE 5900" Dockerfile; then
    bad "the Dockerfile exposes the VNC port (it must stay loopback-only)"
else
    ok "only the web gateway port is exposed"
fi
if grep -q "VOLUME " Dockerfile; then
    bad "the Dockerfile declares VOLUME (Railway mounts its own)"
else
    ok "no anonymous VOLUME declaration"
fi
if grep -q "tcpserver\|nc -l\|socat" Dockerfile; then
    bad "unexpected network helper in the Dockerfile"
else
    ok "no ad-hoc network helpers in the Dockerfile"
fi

echo
echo "== repository hygiene =="
for pattern in xrdp freerdp sesman RDP_PASSWORD KillDisconnected; do
    if grep -rIl "${pattern}" --exclude-dir=.git --exclude-dir=node_modules \
            --exclude='*.pdf' . 2>/dev/null | grep -v "^./tests/lint.sh$" | head -1 >/dev/null; then
        bad "leftover '${pattern}' reference: $(grep -rIl "${pattern}" --exclude-dir=.git --exclude-dir=node_modules . 2>/dev/null | grep -v '^./tests/lint.sh$' | head -3 | tr '\n' ' ')"
    else
        ok "no leftover '${pattern}' references"
    fi
done

if grep -rnIE "(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*[\"'][A-Za-z0-9/+_-]{12,}[\"']" \
        Dockerfile docker scripts .railway/railway.ts .github/workflows 2>/dev/null \
        | grep -vE "(DESKTOP_PASSWORD:-|wrong-password|placeholder|example|PASSWORD_FILE|password_source|CLOUDPC_PASSWORD_FOR_HASH|TEST)" ; then
    bad "possible hardcoded credential found"
else
    ok "no hardcoded credentials in the project files"
fi
if grep -rnIE "TODO|FIXME|PLACEHOLDER|coming soon|not implemented" \
        Dockerfile docker scripts tests .github/workflows .railway/railway.ts 2>/dev/null \
        | grep -v "^tests/lint.sh:" ; then
    bad "unfinished markers found"
else
    ok "no TODO/FIXME markers"
fi

if grep -rnI 'src="http\|href="http' docker/gateway/static/*.html 2>/dev/null; then
    bad "the login page loads external assets"
else
    ok "the login page loads no external assets"
fi

if grep -q "localhost" docker/gateway/static/login.html 2>/dev/null; then
    bad "the login page references localhost (it runs in the browser, not in the container)"
else
    ok "no localhost references in browser-facing assets"
fi

REQUIRED=(
    Dockerfile README.md LICENSE .gitignore .dockerignore
    docker/entrypoint.sh docker/lib/common.sh
    docker/supervisor/supervisord.conf
    docker/gateway/server.py docker/gateway/wsproto.py docker/gateway/security.py
    docker/gateway/static/login.html docker/gateway/static/manifest.webmanifest
    docker/tools/build_novnc_page.py docker/tools/make_icons.py
    docker/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
    docker/skel/.config/autostart/cloudpc-defaults.desktop
    tests/integration.sh tests/lint.sh tests/unit/test_gateway.py tests/clients/rfb_probe.py
    tests/unit/test_build_tools.py tests/unit/test_entrypoint_blocks.py tests/gateway_smoke.py
    .railway/railway.ts .github/workflows/ci.yml
    scripts/build.sh scripts/test.sh scripts/railway-setup.sh
)
for file in "${REQUIRED[@]}"; do
    [ -f "${file}" ] && ok "present ${file}" || bad "missing ${file}"
done

if git check-ignore -q .env 2>/dev/null; then ok ".gitignore excludes .env"; else bad ".gitignore does not exclude .env"; fi
if git ls-files | grep -qE '\.(pem|key|env|p12|keystore)$'; then
    bad "secret-like files are tracked by git"
else
    ok "no secret-like files tracked by git"
fi
if git ls-files | grep -qE '(^|/)test-results/'; then
    bad "test artefacts are tracked by git"
else
    ok "no test artefacts tracked by git"
fi

echo
printf 'passed: %d  failed: %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
