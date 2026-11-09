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

# build residue must not ship (checked first: running the tools below may create /root/.cache)
for f in /var/log/dnf5.log* /var/log/dnf.log*; do
    [ ! -e "$f" ] || fail "build log shipped in the image: $f"
done
for f in /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget; do
    [ ! -e "$f" ] || fail "residue in the image: $f"
done
echo "ok: no dnf logs or root residue (.ssh, .viminfo, .cache, wget) in the image"

# the gaming packages
run rpm -q steam gamescope mangohud gamemode vulkan-tools
command -v steam >/dev/null || fail "steam binary not found"
command -v gamescope >/dev/null || fail "gamescope binary not found"
echo "ok: steam and gamescope resolve"

# Mesa: Vulkan drivers for BOTH architectures, same version, and Terra is gone
v64=$(rpm -q --qf '%{VERSION}-%{RELEASE}' mesa-vulkan-drivers.x86_64) || fail "mesa-vulkan-drivers.x86_64 missing"
v32=$(rpm -q --qf '%{VERSION}-%{RELEASE}' mesa-vulkan-drivers.i686) || fail "mesa-vulkan-drivers.i686 missing"
[ "$v64" = "$v32" ] || fail "mesa-vulkan-drivers differ: x86_64 $v64, i686 $v32"
echo "ok: mesa-vulkan-drivers x86_64 and i686 are both $v64"
if rpm -qa | grep -qi terra; then fail "a Terra package is installed: $(rpm -qa | grep -i terra | tr '\n' ' ')"; fi
if dnf5 repolist --all 2>/dev/null | grep -qi terra; then fail "a Terra repo is still configured"; fi
echo "ok: no Terra repo or package"
libs=$(ldconfig -p | grep libvulkan_radeon)
grep -q 'x86-64' <<<"$libs" || fail "libvulkan_radeon (64-bit) not seen by ldconfig"
grep -v 'x86-64' <<<"$libs" | grep -q libc6 || fail "libvulkan_radeon (32-bit) not seen by ldconfig"
echo "ok: libvulkan_radeon for both architectures"

# a toolbox shares the user's home at runtime: the image must carry nothing user-specific
if [ -d /home ] && [ -n "$(find /home -mindepth 1 -maxdepth 2 2>/dev/null | head -n1)" ]; then
    fail "/home is not empty: $(find /home -mindepth 1 -maxdepth 2 | head -n5 | tr '\n' ' ')"
fi
extra=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | tr '\n' ' ')
[ -z "$extra" ] || fail "image defines regular users: $extra"
echo "ok: no user-specific content in /home or /etc/passwd"

echo "SMOKE PASS"
