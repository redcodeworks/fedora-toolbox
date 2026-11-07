#!/usr/bin/bash
# Install packages/dev.txt into the image. Called from the Containerfile with
# the build context mounted at /ctx. Fails loudly on any unavailable package.
set -euo pipefail

list=/ctx/packages/dev.txt

# Strip comments and blank lines; entries are "name" or "@group-id".
mapfile -t pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list")

if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "build.sh: no packages found in $list" >&2
    exit 1
fi

echo "Installing ${#pkgs[@]} entries from $list"

# dnf5 accepts @group-id as an install argument. No --skip-unavailable and
# strict=1: a missing package or group aborts the build.
dnf5 -y install --setopt=strict=1 "${pkgs[@]}"

dnf5 clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf 2>/dev/null || true
