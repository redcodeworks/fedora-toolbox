#!/usr/bin/bash
# Install the developer package lists of the octarine-bins-dx image into the toolbox. Called from the Containerfile with the build
# context mounted at /ctx and the pinned octarine-bins-dx image at /packages (its lists and its installer). The installer runs required-fedora.txt
# strictly (any unavailable package fails the build) and optional-fedora.txt best effort, then removes the build residue.
#
# The dx lists also carry what the dx OS image needs for hosting virtual machines (libvirt, QEMU, Cockpit's machines module and their tools).
# A development box has no use for those daemons, so they are left out here (EXCLUDE: an excluded entry is not even looked up).
set -euo pipefail

exclude="libvirt qemu-kvm cockpit-machines virt-install virtiofsd swtpm swtpm-tools dnsmasq edk2-ovmf"
exclude+=" virt-manager virt-viewer libvirt-nss qemu-user-binfmt qemu-user-static genisoimage guestfs-tools virt-v2v supermin osbuild osbuild-selinux udica"

EXCLUDE="${exclude}" bash /packages/install.sh
