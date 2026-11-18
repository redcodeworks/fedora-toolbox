#!/usr/bin/bash
# Install the package lists of this image (../packages next to build_files, or PACKAGES_DIR) with dnf5.
# Derived from the installer of octarine-bins (commit f1507cc), cut down to what the toolbox images use.
#
# One list per tier and source, installed in this order (a missing list file is skipped):
#   required-fedora.txt  required-negativo17.txt   STRICT: one dnf5 transaction per file, any failure fails the build
#   optional-fedora.txt                            BEST EFFORT: never fails the build, what cannot be installed is printed
#
# List format: one token per line, blank lines and #-comments ignored; `name`, `name.arch`, `@group-id`, or `a|b|c`
# alternatives (the FIRST one that exists in the enabled repositories is installed; none existing fails a required
# file and is reported for an optional one). negativo17 is the repository with the id fedora-multimedia: it must be
# defined (disabled) by the caller; it is enabled for the negativo17 list only.
#
# An optional list is ONE transaction; on failure it is retried once as a whole, then package by package. A package that
# still cannot be installed is printed as `OPTIONAL PACKAGE MISSING: <name>`.
#
# Environment:
#   EXCLUDE="a b"       drop entries (a name, an alternative of an entry, an @group); an excluded entry is not looked up
#   PACKAGES_DIR=<dir>  where the lists are (default: ../packages)
#
# Not done here: dnf cache and residue cleanup (the calling build.sh does it).
set -eoux pipefail

dir=${PACKAGES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../packages" && pwd)}
negativo17_repo=fedora-multimedia

declare -A excluded=()
for x in ${EXCLUDE:-}; do excluded["${x}"]=1; done

die() { echo "install-packages.sh: $*" >&2; exit 1; }

missing() { echo "OPTIONAL PACKAGE MISSING: $1${2:+ ($2)}"; }

# true when the package exists in the enabled repositories (exact name match)
exists() { # <name> <repo arg>...
    local n=$1 out; shift
    out=$(dnf5 -q repoquery "$@" --available --latest-limit=1 --queryformat '%{name}\n' "${n}") || return 1
    grep -Fxq -- "${n}" <<<"${out}"
}

# the tokens of a list file, comments and blanks dropped
entries() { sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# resolve <tier> <expected count> <repo arg>...  (entries on stdin): applies EXCLUDE and the alternatives and prints the
# package arguments to install. The entries are read into an array FIRST: dnf5 inside `exists` would otherwise read the
# loop's stdin and silently end it. The counts must add up or the build fails.
resolve() {
    local tier=$1 want=$2 entry a pick skip n_pick=0 n_excl=0 n_miss=0; shift 2
    local alts=() list=()
    mapfile -t list
    [[ "${#list[@]}" -eq "${want}" ]] || die "read ${#list[@]} of ${want} entries"
    for entry in "${list[@]}"; do
        [[ ! "${entry}" =~ [[:space:]] ]] || die "more than one token on a line: '${entry}'"
        IFS='|' read -r -a alts <<<"${entry}"
        skip=""
        for a in "${alts[@]}"; do [[ -z "${excluded[${a}]:-}" ]] || { skip=${a}; break; }; done
        if [[ -n "${skip}" ]]; then echo "excluded: ${entry} (EXCLUDE has ${skip})" >&2; n_excl=$((n_excl + 1)); continue; fi
        if [[ "${#alts[@]}" -eq 1 ]]; then echo "${entry}"; n_pick=$((n_pick + 1)); continue; fi
        for a in "${alts[@]}"; do
            [[ -n "${a}" && "${a}" != @* ]] || die "bad alternative in '${entry}' (empty, or a group: groups cannot have alternatives)"
        done
        pick=""
        for a in "${alts[@]}"; do if exists "${a}" "$@"; then pick=${a}; break; fi; done
        if [[ -n "${pick}" ]]; then
            echo "resolved: ${entry} -> ${pick}" >&2
            echo "${pick}"; n_pick=$((n_pick + 1))
        elif [[ "${tier}" == required ]]; then
            die "none of the alternatives exists in the enabled repositories: ${entry}"
        else
            missing "${entry}" "no alternative exists" >&2; n_miss=$((n_miss + 1))
        fi
    done
    [[ $((n_pick + n_excl + n_miss)) -eq "${want}" ]] || die "${n_pick} installed + ${n_excl} excluded + ${n_miss} missing is not the ${want} entries"
}

# dnf_install <tier> <repo arg>... -- <package>...
dnf_install() {
    local tier=$1; shift
    local args=()
    while [[ "$1" != -- ]]; do args+=("$1"); shift; done; shift
    if [[ "${tier}" == required ]]; then dnf5 -y install --setopt=strict=1 "${args[@]}" "$@"; else dnf5 -y install "${args[@]}" "$@"; fi
}

# optional <repo arg>... -- <package>...: one transaction; on failure once more as a whole, then one by one
optional() {
    local args=()
    while [[ "$1" != -- ]]; do args+=("$1"); shift; done; shift
    local pkg
    [[ $# -gt 0 ]] || return 0
    if dnf_install optional "${args[@]}" -- "$@"; then return 0; fi
    echo "WARNING: the optional list failed, retrying it once as a whole"
    sleep 20
    dnf5 clean expire-cache > /dev/null 2>&1 || true
    if dnf_install optional "${args[@]}" -- "$@"; then return 0; fi
    echo "WARNING: the optional list failed as a whole twice, retrying its packages one by one"
    for pkg in "$@"; do
        dnf_install optional "${args[@]}" -- "${pkg}" || missing "${pkg}"
    done
}

for tier in required optional; do
    for source in fedora negativo17; do
        file=${dir}/${tier}-${source}.txt
        [[ -f "${file}" ]] || continue
        [[ -n "$(entries "${file}")" ]] || { echo "${file} lists nothing, skipped"; continue; }
        repo_args=()
        [[ "${source}" != negativo17 ]] || repo_args+=("--enable-repo=${negativo17_repo}")
        # (a command substitution, not mapfile < <(...): a failing resolve must fail the build)
        resolved=$(entries "${file}" | resolve "${tier}" "$(entries "${file}" | wc -l)" "${repo_args[@]}")
        pkgs=()
        [[ -z "${resolved}" ]] || mapfile -t pkgs <<<"${resolved}"
        echo "Installing ${#pkgs[@]} ${tier} entries from ${file}"
        if [[ "${tier}" == required ]]; then
            [[ "${#pkgs[@]}" -gt 0 ]] || die "nothing to install from ${file}"
            dnf_install required "${repo_args[@]}" -- "${pkgs[@]}"
        else
            optional "${repo_args[@]}" -- "${pkgs[@]}"
        fi
    done
done
