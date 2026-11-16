#!/usr/bin/env bash
# Install COPR packages from a list, pinned to an exact version. The COPR counterpart of install.sh; each
# manifest image that has a COPR list carries it as /install-copr.sh.
#
#   install-copr.sh LIST_FILE
#
# List syntax (one entry per line, blank lines and #-comments ignored):
#   owner/project:name-version-release     for example  lizardbyte/stable:Sunshine-2026.914.233613-1.fc45
# The name is case sensitive. An entry without an exact version and release is rejected.
#
# For every entry, in order: `dnf5 -y copr enable owner/project`, ONE transaction
# `dnf5 -y install --setopt=strict=1 name-version-release`, then `dnf5 -y copr disable owner/project`
# (always, also when the install failed, so the COPR never stays enabled in the image). A failure
# fails the build with a message naming the entry; nothing is skipped.
#
# Environment:
#   NO_CLEANUP=1   skip the cleanup at the end (a caller that installs several lists cleans up itself)
#   CLEANUP_ROOT=<dir>  prefix for the cleanup paths (tests only)
#
# Needs dnf5 with the copr plugin (the package dnf5-plugins) and runs as root.
set -euo pipefail

list=${1:-}
[[ -n "${list}" ]] || { echo "install-copr.sh: name the list to install" >&2; exit 1; }
[[ -f "${list}" ]] || { echo "install-copr.sh: list not found: ${list}" >&2; exit 1; }

mapfile -t entries < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "${list}")
[[ "${#entries[@]}" -gt 0 ]] || { echo "install-copr.sh: nothing to install from ${list}" >&2; exit 1; }

# owner/project:name-version-release, the version starts with a digit, no dash inside version or release
nvr_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_.+]+(-[A-Za-z0-9_.+]+)*-[0-9][A-Za-z0-9_.+~^]*-[0-9][A-Za-z0-9_.+~^]*$'
for entry in "${entries[@]}"; do
    [[ "${entry}" =~ ${nvr_re} ]] || {
        echo "install-copr.sh: '${entry}' is not owner/project:name-version-release (an exact version and release is required)" >&2
        exit 1
    }
done

# the copr plugin must be there, with a clear message instead of a dnf5 usage error
if ! dnf5 copr --help >/dev/null 2>&1; then
    echo "install-copr.sh: dnf5 has no 'copr' command; install the package dnf5-plugins first" >&2
    exit 1
fi

enabled=""
disable() {
    if [[ -n "${enabled}" ]]; then
        dnf5 -y copr disable "${enabled}" || echo "install-copr.sh: WARNING could not disable the COPR ${enabled}" >&2
        enabled=""
    fi
}
trap disable EXIT

for entry in "${entries[@]}"; do
    repo=${entry%%:*}
    pkg=${entry#*:}
    echo "COPR ${repo}: ${pkg}"
    enabled=${repo}
    dnf5 -y copr enable "${repo}" || { echo "install-copr.sh: could not enable the COPR ${repo}" >&2; exit 1; }
    dnf5 -y install --setopt=strict=1 "${pkg}" || { echo "install-copr.sh: could not install ${pkg} from the COPR ${repo}" >&2; exit 1; }
    disable
done

trap - EXIT
if [[ "${NO_CLEANUP:-}" == "1" ]]; then
    echo "NO_CLEANUP=1: skipping the cleanup"
    exit 0
fi

dnf5 clean all
r=${CLEANUP_ROOT:-}
rm -rf "${r}"/var/cache/libdnf5 "${r}"/var/cache/dnf "${r}"/var/log/dnf5.log* "${r}"/var/log/dnf.log* \
    "${r}"/root/.ssh "${r}"/root/.viminfo "${r}"/root/.cache "${r}"/root/.local/share/wget \
    "${r}"/root/.wget-hsts 2>/dev/null || true
