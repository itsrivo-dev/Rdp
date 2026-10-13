#!/usr/bin/env bash
# =============================================================================
#  Static checks - no Docker required.
#    * bash syntax + shellcheck for every shell script
#    * python syntax/compile for the status server
#    * JSON / XML / INI template well-formedness
#    * Dockerfile sanity (no secrets, no placeholder TODOs)
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
    docker/bin/cloudpc-health
    docker/bin/cloudpc-watchdog
    docker/bin/cloudpc-credentials
    docker/bin/cloudpc-status
    docker/xrdp/startwm.sh
    docker/xrdp/reconnectwm.sh
    tests/integration.sh
    tests/lint.sh
    scripts/build.sh
    scripts/test.sh
    scripts/railway-setup.sh
)

echo "== shell syntax =="
for f in "${SHELL_SCRIPTS[@]}"; do
    [ -f "$f" ] || { bad "missing $f"; continue; }
    if head -1 "$f" | grep -q 'bash'; then interp="bash"; else interp="sh"; fi
    if "${interp}" -n "$f" 2>/tmp/synerr; then ok "syntax $f"; else bad "syntax $f: $(cat /tmp/synerr)"; fi
done

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${SHELL_SCRIPTS[@]}"; do
        [ -f "$f" ] || continue
        if shellcheck -S warning -e SC1091 "$f" >/tmp/sc.out 2>&1; then
            ok "shellcheck $f"
        else
            bad "shellcheck $f"
            sed 's/^/     /' /tmp/sc.out | head -25
        fi
    done
else
    note "shellcheck not installed - skipping"
fi

echo
echo "== python =="
if python3 -m py_compile docker/health/server.py 2>/tmp/pyerr; then
    ok "compile docker/health/server.py"
else
    bad "compile docker/health/server.py: $(cat /tmp/pyerr)"
fi

echo
echo "== embedded python in entrypoint =="
python3 - <<'PY'
import re
import sys

src = open("docker/entrypoint.sh", encoding="utf-8").read()
blocks = re.findall(r"<<'?PY'?\n(.*?)\nPY\n", src, re.S)
if not blocks:
    print("FAIL no embedded python blocks found")
    sys.exit(1)
for i, block in enumerate(blocks):
    try:
        compile(block, f"<entrypoint block {i}>", "exec")
        print(f"PASS embedded python block {i} compiles")
    except SyntaxError as exc:
        print(f"FAIL embedded python block {i}: {exc}")
        sys.exit(1)
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo
echo "== xml / json / config =="
while IFS= read -r f; do
    if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$f" 2>/dev/null; then
        ok "xml $f"
    else
        bad "xml $f"
    fi
done < <(find docker/skel -name '*.xml' 2>/dev/null)
if [ -f .railway/railway.ts ]; then ok "railway IaC file present"; else bad ".railway/railway.ts missing"; fi
for f in docker/xrdp/xrdp.ini.tmpl docker/xrdp/sesman.ini.tmpl docker/supervisor/supervisord.conf; do
    if python3 - "$f" <<'PY'
import configparser, re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# xrdp uses ';' comments, supervisord uses ';' too - configparser handles both
# once we allow duplicate-free strict parsing to be relaxed.
cp = configparser.ConfigParser(strict=False, interpolation=None, comment_prefixes=(";", "#"))
cp.read_string(re.sub(r"@@([A-Z0-9_]+)@@", r"placeholder", text))
assert cp.sections(), "no sections"
PY
    then ok "ini $f"; else bad "ini $f"; fi
done

echo
echo "== template placeholders are all provided by the entrypoint =="
python3 - <<'PY'
import re
import sys

entry = open("docker/entrypoint.sh", encoding="utf-8").read()
missing = []
for tmpl in ("docker/xrdp/xrdp.ini.tmpl", "docker/xrdp/sesman.ini.tmpl"):
    for key in sorted(set(re.findall(r"@@([A-Z0-9_]+)@@", open(tmpl, encoding="utf-8").read()))):
        if not re.search(r"\bexport\b[^\n]*\b%s\b" % key, entry):
            missing.append(f"{tmpl}:{key}")
if missing:
    print("FAIL template variables never exported: " + ", ".join(missing))
    sys.exit(1)
print("PASS every template placeholder is exported by the entrypoint")
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo
echo "== repository hygiene =="
SCAN_PATHS=(Dockerfile docker scripts .railway/railway.ts .github tests/integration.sh)
if grep -rnIE "(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*[\"'][A-Za-z0-9/+_-]{8,}[\"']" \
        "${SCAN_PATHS[@]}" 2>/dev/null \
        | grep -vE "(RDP_PASSWORD:-|wrong-password|placeholder|example|PASSWORD_FILE|password_source|CLOUDPC_PASSWORD_FOR_HASH)"; then
    bad "possible hardcoded credential found"
else
    ok "no hardcoded credentials"
fi
if grep -rnIE "TODO|FIXME|PLACEHOLDER|coming soon|not implemented" "${SCAN_PATHS[@]}" 2>/dev/null; then
    bad "unfinished markers found"
else
    ok "no TODO/FIXME markers"
fi
for required in Dockerfile README.md LICENSE .gitignore .dockerignore docker/entrypoint.sh \
                docker/supervisor/supervisord.conf docker/health/server.py \
                docker/xrdp/xrdp.ini.tmpl docker/xrdp/sesman.ini.tmpl .railway/railway.ts \
                scripts/railway-setup.sh tests/integration.sh; do
    [ -f "${required}" ] && ok "present ${required}" || bad "missing ${required}"
done
if git check-ignore -q .env 2>/dev/null; then ok ".gitignore excludes .env"; else bad ".gitignore does not exclude .env"; fi
if git ls-files | grep -qE '\.(pem|key|env)$'; then bad "secret-like files are tracked by git"; else ok "no secret-like files tracked"; fi

echo
printf 'passed: %d  failed: %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
