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

run gcc --version
run g++ --version
run make --version
run cmake --version
run ninja --version
run meson --version
run clang --version
run pkg-config --version
run uv --version
run rustup --version
run fish --version

# .pc modules for the headline -devel packages
for mod in openssl sqlite3 glib-2.0 libpq; do
    pkg-config --exists "$mod" || fail "pkg-config module '$mod' not found"
    echo "ok: pkg-config $mod $(pkg-config --modversion "$mod")"
done

# compile and link a small C program against libc and libm
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/t.c" <<'EOF'
#include <stdio.h>
#include <math.h>
int main(void) { printf("%.0f\n", sqrt(16.0)); return 0; }
EOF
gcc -o "$tmp/t" "$tmp/t.c" -lm || fail "C compile/link failed"
[ "$("$tmp/t")" = "4" ] || fail "compiled program gave wrong output"
echo "ok: C compile and link"

# the image must carry nothing user-specific: the home is shared at runtime
if [ -d /home ] && [ -n "$(find /home -mindepth 1 -maxdepth 2 2>/dev/null | head -n1)" ]; then
    fail "/home is not empty: $(find /home -mindepth 1 -maxdepth 2 | head -n5 | tr '\n' ' ')"
fi
extra=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | tr '\n' ' ')
[ -z "$extra" ] || fail "image defines regular users: $extra"
echo "ok: no user-specific content in /home or /etc/passwd"

echo "SMOKE PASS"
