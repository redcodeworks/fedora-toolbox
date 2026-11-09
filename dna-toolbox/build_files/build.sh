#!/usr/bin/bash
# Install packages/core.txt (strict) and packages/optional.txt (best effort) into the image. Called from the Containerfile with the build context
# mounted at /ctx. Fails loudly on any unavailable package.
set -euo pipefail

list=/ctx/packages/core.txt
optional=/ctx/packages/optional.txt

# Strip comments and blank lines; entries are "name" or "@group-id".
mapfile -t pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list")

if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "build.sh: no packages found in $list" >&2
    exit 1
fi

echo "Installing ${#pkgs[@]} entries from $list"

# No --skip-unavailable and strict=1: a missing package or group aborts the build.
dnf5 -y install --setopt=strict=1 "${pkgs[@]}"

# Optional tier: one package at a time, failures are logged and never fail the build.
mapfile -t opt < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$optional")
for p in "${opt[@]}"; do
    dnf5 -y install "$p" || echo "build.sh: WARNING optional package '$p' not installed" >&2
done

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
