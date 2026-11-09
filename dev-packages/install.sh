#!/usr/bin/env bash
# Install the developer package list into the image that is being built.
#
#   install.sh [LIST_FILE]        default: dev.txt next to this script
#
# List syntax (one entry per line, blank lines and #-comments ignored):
#   name        a package
#   @group-id   a package group
#   a|b|c       alternatives: the FIRST one that exists in the enabled repositories is installed;
#               none existing is an error (groups cannot have alternatives)
#
# Environment:
#   EXCLUDE="name1 name2"   drop entries (a name, an alternative of an entry, or an @group) from the
#                           install; printed. An excluded entry is not looked up, so it may be
#                           unavailable on the consumer's release.
#   NO_CLEANUP=1            skip the cleanup at the end
#   CLEANUP_ROOT=<dir>      prefix for the cleanup paths (tests only)
#
# Needs dnf5 and runs as root. Works from a bind mount, for example:
#   RUN --mount=type=bind,from=devpkgs,source=/,target=/dev-packages bash /dev-packages/install.sh
# Fails loudly: no --skip-unavailable, any unavailable package or group aborts (strict=1).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
list=${1:-${here}/dev.txt}
[[ -f "${list}" ]] || { echo "install.sh: list not found: ${list}" >&2; exit 1; }

declare -A excluded=()
for x in ${EXCLUDE:-}; do excluded["${x}"]=1; done

# true when the package exists in the enabled repositories (exact name match)
exists() {
    local out
    out=$(dnf5 -q repoquery --available --latest-limit=1 --queryformat '%{name}\n' "$1") || return 1
    grep -Fxq -- "$1" <<<"${out}"
}

resolved=()
mapfile -t entries < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "${list}")

for entry in "${entries[@]}"; do
    if [[ "${entry}" =~ [[:space:]] ]]; then
        echo "install.sh: more than one token on a line: '${entry}'" >&2
        exit 1
    fi
    IFS='|' read -r -a alts <<<"${entry}"
    skip=""
    for a in "${alts[@]}"; do
        if [[ -n "${excluded[${a}]:-}" ]]; then skip="${a}"; break; fi
    done
    if [[ -n "${skip}" ]]; then
        echo "excluded: ${entry} (EXCLUDE has ${skip})"
        continue
    fi
    if [[ "${#alts[@]}" -eq 1 ]]; then
        resolved+=("${entry}")
        continue
    fi
    for a in "${alts[@]}"; do
        if [[ -z "${a}" || "${a}" == @* ]]; then
            echo "install.sh: bad alternative in '${entry}' (empty, or a group: groups cannot have alternatives)" >&2
            exit 1
        fi
    done
    pick=""
    for a in "${alts[@]}"; do
        if exists "${a}"; then pick="${a}"; break; fi
    done
    if [[ -z "${pick}" ]]; then
        echo "install.sh: none of the alternatives exists in the enabled repositories: ${entry}" >&2
        exit 1
    fi
    echo "resolved: ${entry} -> ${pick}"
    resolved+=("${pick}")
done

if [[ "${#resolved[@]}" -eq 0 ]]; then
    echo "install.sh: nothing to install from ${list}" >&2
    exit 1
fi

echo "Installing ${#resolved[@]} entries from ${list}"
dnf5 -y install --setopt=strict=1 "${resolved[@]}"

if [[ "${NO_CLEANUP:-}" == "1" ]]; then
    echo "NO_CLEANUP=1: skipping the cleanup"
    exit 0
fi

dnf5 clean all
# Build residue that must not ship: dnf logs (they contain mirror URLs), root's ssh, vim, wget and
# cache leftovers, and the dnf caches
r=${CLEANUP_ROOT:-}
rm -rf "${r}"/var/cache/libdnf5 "${r}"/var/cache/dnf "${r}"/var/log/dnf5.log* "${r}"/var/log/dnf.log* \
    "${r}"/root/.ssh "${r}"/root/.viminfo "${r}"/root/.cache "${r}"/root/.local/share/wget \
    "${r}"/root/.wget-hsts 2>/dev/null || true
