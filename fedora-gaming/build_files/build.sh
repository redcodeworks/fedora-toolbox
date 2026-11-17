#!/usr/bin/bash
# Build the gaming toolbox: drop Terra so Fedora's Mesa is the only Mesa (x86_64 and i686 from the
# same repo and version), then install the lists of the octarine-bins-gx image through its installer. Called from the Containerfile with the
# build context mounted at /ctx. Fails loudly on any unavailable package.
set -euo pipefail

# (a) Drop Terra. The base keeps Terra's Mesa for x86_64 only and hides Fedora's Mesa with an
# `exclude=mesa-*` override on the fedora repos; Steam needs 32-bit Mesa, which Fedora ships.
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

# (c) Steam comes from negativo17 (repo id fedora-multimedia). This base does not configure it (the Universal Blue OS base does), so write the
# same repository definition, DISABLED; the installer enables it for the negativo17 list only.
cat > /etc/yum.repos.d/negativo17-fedora-multimedia.repo <<'REPO'
[fedora-multimedia]
name=negativo17 - Multimedia
baseurl=https://negativo17.org/repos/multimedia/fedora-$releasever/$basearch/
enabled=0
skip_if_unavailable=1
gpgkey=https://negativo17.org/repos/RPM-GPG-KEY-slaanesh
gpgcheck=1
enabled_metadata=1
metadata_expire=6h
type=rpm-md
repo_gpgcheck=0
REPO

# (d) The package lists of the octarine-bins-gx image (mounted at /packages) through its installer: required-fedora.txt, then
# required-negativo17.txt (Steam and the newer Mesa, codec and libva builds it pulls in), strict; then optional-fedora.txt, best effort. A missing
# required package aborts the build. required-copr.txt (Sunshine) is for the gx OS image and is NOT installed here: the installer runs on a copy of the
# lists without it. This script does its own cleanup (NO_CLEANUP=1).
lists=$(mktemp -d)
cp /packages/install.sh /packages/*.txt "${lists}/"
rm -f "${lists}"/*-copr.txt
PACKAGES_DIR="${lists}" NO_CLEANUP=1 bash "${lists}/install.sh"
rm -rf "${lists}"

# Record what Mesa the image ended up with (shows in the build log)
rpm -qa --qf '%{NAME}.%{ARCH} %{VERSION}-%{RELEASE} %{VENDOR}\n' 'mesa-*' | sort

dnf5 clean all
# Build residue that must not ship: dnf logs (they contain mirror URLs), root's ssh, vim, wget and
# cache leftovers, and the dnf caches
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* \
    /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts 2>/dev/null || true
