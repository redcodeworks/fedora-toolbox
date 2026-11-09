#!/usr/bin/env bash
# Scaffold a new TOOLBOX image directory: <name>/{Containerfile,build_files/build.sh,packages/dev.txt,
# tests/smoke.sh}. FROM a toolbox base, no OS-image parts (no bootc, ostree, kernel, disk or ISO
# steps). The image name is the directory name (add <name>/image.env to override it).
#
#   new-image.sh <name>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=images.sh
source "${here}/images.sh"

name="${1:?usage: new-image.sh <name>}"
[[ "${name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "name must be lowercase letters, digits and dashes" >&2; exit 1; }
dir="${root}/${name}"
[[ ! -e "${dir}" ]] || { echo "${name} already exists" >&2; exit 1; }

mkdir -p "${dir}/build_files" "${dir}/packages" "${dir}/tests"

cat > "${dir}/Containerfile" <<EOF
# Build context is mounted, not copied into the final image
FROM scratch AS ctx
COPY build_files /build_files
COPY packages /packages

# Toolbox base (Universal Blue, github.com/ublue-os/toolboxes). Renovate pins the digest.
FROM ghcr.io/ublue-os/fedora-toolbox:latest

LABEL org.opencontainers.image.title="${name}" \\
      org.opencontainers.image.description="TODO: what this toolbox is for" \\
      org.opencontainers.image.source="https://github.com/redcodeworks/fedora-toolbox"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \\
    --mount=type=cache,dst=/var/cache \\
    bash /ctx/build_files/build.sh
EOF

cat > "${dir}/build_files/build.sh" <<'EOF'
#!/usr/bin/bash
# Install packages/dev.txt into the image. Called from the Containerfile with the build context
# mounted at /ctx. Fails loudly on any unavailable package.
set -euo pipefail

list=/ctx/packages/dev.txt

# Strip comments and blank lines; entries are "name" or "@group-id".
mapfile -t pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list")

if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "build.sh: no packages found in $list" >&2
    exit 1
fi

echo "Installing ${#pkgs[@]} entries from $list"

# No --skip-unavailable and strict=1: a missing package or group aborts the build.
dnf5 -y install --setopt=strict=1 "${pkgs[@]}"

dnf5 clean all
# Build residue that must not ship: dnf logs (mirror URLs), root's ssh/vim/wget/cache leftovers
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* \
    /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts 2>/dev/null || true
EOF

cat > "${dir}/packages/dev.txt" <<'EOF'
# One package or @group per line; blank lines and #-comments are ignored.
# Official Fedora packages only (plus whatever the base already configures).
# A package that cannot be installed fails the build.
make
EOF

cat > "${dir}/tests/smoke.sh" <<'EOF'
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
run make --version

# A toolbox shares the user's home at runtime: the image must carry nothing user-specific
if [ -d /home ] && [ -n "$(find /home -mindepth 1 -maxdepth 2 2>/dev/null | head -n1)" ]; then
    fail "/home is not empty"
fi
extra=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | tr '\n' ' ')
[ -z "$extra" ] || fail "image defines regular users: $extra"
echo "ok: no user-specific content in /home or /etc/passwd"

echo "SMOKE PASS"
EOF

chmod +x "${dir}/build_files/build.sh" "${dir}/tests/smoke.sh"
echo "Created ${name}/. Edit packages/dev.txt and tests/smoke.sh, then: just build ${name} && just smoke ${name}"
