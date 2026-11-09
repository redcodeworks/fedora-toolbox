#!/usr/bin/bash
# Build the gaming toolbox: drop Terra so Fedora's Mesa is the only Mesa (x86_64 and i686 from the
# same repo and version), then install packages/gaming.txt. Called from the Containerfile with the
# build context mounted at /ctx. Fails loudly on any unavailable package.
set -euo pipefail

list=/ctx/packages/gaming.txt

# (a) Drop Terra. The base keeps Terra's Mesa for x86_64 only and hides Fedora's Mesa with an
# `exclude=mesa-*` override on the fedora repos; Steam needs 32-bit Mesa, which only Fedora ships.
rm -f /etc/yum.repos.d/terra*.repo
rpm -qa 'terra*' | xargs -r rpm -e --nodeps
rm -f /etc/dnf/repos.override.d/99-config_manager.repo
if grep -rIli 'terra' /etc/yum.repos.d /etc/dnf/repos.override.d 2>/dev/null; then
    echo "build.sh: Terra configuration is still present" >&2
    exit 1
fi

# (b) Put x86_64 Mesa on Fedora's version (newer than Terra's); i686 Mesa then comes from the same
# repo with the same version when Steam's dependencies are installed below.
dnf5 -y distro-sync --refresh 'mesa*'

# (c) The package list: "name", "name.arch" or "@group" per line, comments allowed.
mapfile -t pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list")
if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "build.sh: no packages found in $list" >&2
    exit 1
fi
echo "Installing ${#pkgs[@]} entries from $list"
# No --skip-unavailable and strict=1: a missing package aborts the build.
dnf5 -y install --setopt=strict=1 "${pkgs[@]}"

# Record what Mesa the image ended up with (shows in the build log)
rpm -qa --qf '%{NAME}.%{ARCH} %{VERSION}-%{RELEASE} %{VENDOR}\n' 'mesa-*' | sort

dnf5 clean all
# Build residue that must not ship: dnf logs (they contain mirror URLs), root's ssh, vim, wget and
# cache leftovers, and the dnf caches
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* \
    /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts 2>/dev/null || true
