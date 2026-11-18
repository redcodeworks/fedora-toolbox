#!/usr/bin/bash
# Install the developer package lists (packages/required-fedora.txt strictly, optional-fedora.txt best effort) into the toolbox through
# install-packages.sh. Called from the Containerfile with the build context mounted at /ctx. Any unavailable required package fails the build.
#
# The lists also carry what the dx OS image needs for hosting virtual machines (libvirt, QEMU, Cockpit's machines module and their tools).
# A development box has no use for those daemons, so they are left out here (EXCLUDE: an excluded entry is not even looked up).
set -euo pipefail

exclude="libvirt qemu-kvm cockpit-machines virt-install virtiofsd swtpm swtpm-tools dnsmasq edk2-ovmf"
exclude+=" virt-manager virt-viewer libvirt-nss qemu-user-binfmt qemu-user-static genisoimage guestfs-tools virt-v2v supermin osbuild osbuild-selinux udica"

EXCLUDE="${exclude}" bash /ctx/build_files/install-packages.sh

dnf5 clean all
# Build residue that must not ship: dnf logs (they contain mirror URLs), root's ssh, vim, wget and
# cache leftovers, and the dnf caches
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* \
    /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts 2>/dev/null || true
