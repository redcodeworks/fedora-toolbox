#!/usr/bin/bash
# Smoke test, run INSIDE the built image:
#   podman run --rm -v ./tests/smoke.sh:/smoke.sh:ro <image> bash /smoke.sh
# Fails on the first missing piece.
set -euo pipefail

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

run() {
    local out
    out=$("$@" 2>&1) || fail "'$*' failed: $out"
    echo "ok: $* -> $(head -n1 <<<"$out")"
}

# TODO: one line per tool this toolbox must provide

# A toolbox shares the user's home at runtime: the image must carry nothing user-specific
if [ -d /home ] && [ -n "$(find /home -mindepth 1 -maxdepth 2 2>/dev/null | head -n1)" ]; then
    fail "/home is not empty"
fi
extra=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | tr '\n' ' ')
[ -z "$extra" ] || fail "image defines regular users: $extra"
echo "ok: no user-specific content in /home or /etc/passwd"

# critical tools only (optional.txt packages are never required)
run uv --version
command -v rocminfo >/dev/null || fail "rocminfo missing"
command -v rocm-smi >/dev/null || fail "rocm-smi missing"
echo "ok: uv, rocminfo, rocm-smi"

echo "SMOKE PASS"
