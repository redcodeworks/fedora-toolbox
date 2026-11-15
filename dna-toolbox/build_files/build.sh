#!/usr/bin/bash
# Install dna-packages/core.txt (strict) and dna-packages/optional.txt (best effort) into the image through the shared
# installer. Called from the Containerfile with the build context mounted at /ctx. Fails loudly on any unavailable
# core package.
set -euo pipefail

# Core tier: one strict dnf5 install (no --skip-unavailable, strict=1: a missing package or group aborts the build).
# Optional tier: one package at a time, failures are logged and never fail the build. The installer strips comments
# and blank lines; this script does its own cleanup at the end (NO_CLEANUP=1).
NO_CLEANUP=1 bash /ctx/dna-packages/install.sh /ctx/dna-packages/core.txt
NO_CLEANUP=1 OPTIONAL=1 bash /ctx/dna-packages/install.sh /ctx/dna-packages/optional.txt

# Pinned versions, config files (conda-forge-only condarc, profile script, notebooks), the dna-*
# commands. Files only; nothing runs at build time.
# shellcheck source=/dev/null
source /ctx/versions.env
cp -r /ctx/files/. /
install -d /usr/share/dna-toolbox
install -m 0644 /ctx/versions.env /ctx/downloads.lock /usr/share/dna-toolbox/
install -m 0755 /ctx/bin_dna/* /usr/bin/

# Pinned vendor downloads (optional tier: failures only warn). Format: name|version|url|sha256|file
while IFS='|' read -r name version url sha file; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    tmp=$(mktemp -d)
    if curl -fsSL --retry 3 -o "${tmp}/a.tgz" "${url}" \
        && echo "${sha}  ${tmp}/a.tgz" | sha256sum -c - >/dev/null \
        && tar -xzf "${tmp}/a.tgz" -C "${tmp}" "${file}"; then
        install -m 0755 "${tmp}/${file}" "/usr/local/bin/${file}"
        echo "installed ${name} ${version}"
    else
        echo "build.sh: WARNING ${name} ${version} not installed (download or checksum failed)" >&2
    fi
    rm -rf "${tmp}"
done < /ctx/downloads.lock

# The server stack tooling (Quadlet and compose files, the dna-stack command): files only, nothing
# runs at build time
install -d /usr/share/dna-stack
cp -r /ctx/stack/. /usr/share/dna-stack/
chmod 0755 /usr/share/dna-stack/bin/dna-stack
ln -sf /usr/share/dna-stack/bin/dna-stack /usr/bin/dna-stack

dnf5 clean all
# Build residue that must not ship: dnf logs (mirror URLs), root's ssh/vim/wget/cache leftovers
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* \
    /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts 2>/dev/null || true
