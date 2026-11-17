#!/usr/bin/env bash
# Lint the repo: script syntax (and shellcheck at warning level, CI only unless installed), the layout of every image directory,
# the package lists and bins pins, unique image names, and the "toolbox images only" rule (no OS-image parts).
# REPO_ROOT overrides the repository root (the scaffold test lints a temporary copy).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=images.sh
source "${here}/images.sh"
cd "${root}"

fail=0
err() { echo "lint: $*" >&2; fail=1; }

shopt -s nullglob
scripts=(.github/scripts/*.sh tests/*.sh ./*/build_files/*.sh ./*/tests/*.sh ./datastore-images/validate.sh ./datastore-images/check-bundle.sh ./datastore-images/lib/*.sh ./*/stack/bin/* ./*/bin/*)
bash -n "${scripts[@]}" || fail=1
if command -v shellcheck >/dev/null; then
    # -S warning: only warnings and errors fail; info and style findings are not for the first CI run
    shellcheck -S warning -x -P SCRIPTDIR "${scripts[@]}" || fail=1
else
    echo "lint: WARNING: shellcheck is not installed here, so the shellcheck step did NOT run (CI runs it)" >&2
fi

names=()
for d in $(image_dirs); do
    n=$(image_name "${d}")
    [[ "${n}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || err "${d}: image name '${n}' must be lowercase (a-z, 0-9, . _ -)"
    names+=("${n}")
    grep -qE '^FROM ' "${d}/Containerfile" || err "${d}/Containerfile has no FROM line"
    kind=$(image_kind "${d}")
    lists=()
    if [[ "${kind}" == "list" ]]; then
        # data image (datastore-images): FROM scratch, checked by its own validator and DATA_FILES, no toolbox parts
        grep -qE '^FROM scratch$' "${d}/Containerfile" || err "${d}/Containerfile: a list image is FROM scratch"
        [[ -f "${d}/README.md" ]] || err "${d}/README.md missing"
        validator=$(_env_var "${d}" LIST_VALIDATOR)
        if [[ -n "${validator}" ]]; then
            [[ -x "${validator}" ]] || err "${d}/image.env: LIST_VALIDATOR ${validator} missing or not executable"
            for list in "${d}"/*.txt; do
                "${validator}" "${list}" >/dev/null || err "${list}: failed ${validator}"
            done
        fi
        [[ -n "$(image_data_files "${d}")" ]] || err "${d}/image.env: DATA_FILES missing (the build checks the image against the repository)"
        while IFS=: read -r srcpath _; do
            [[ -f "${srcpath}" ]] || err "${d}/image.env: DATA_FILES names ${srcpath}, which does not exist"
        done < <(image_data_files "${d}")
    else
        [[ -x "${d}/tests/smoke.sh" ]] || err "${d}/tests/smoke.sh missing or not executable"
        [[ -f "${d}/build_files/build.sh" ]] || err "${d}/build_files/build.sh missing"
        lists=("${d}"/packages/*.txt)
        # an image that takes its lists from an octarine-bins image (fedora-toolbox, fedora-gaming) has none of its own
        if [[ ${#lists[@]} -eq 0 ]] && ! grep -qE '^FROM ghcr\.io/redcodeworks/octarine-bins-(dx|gx)@' "${d}/Containerfile"; then
            err "${d}/packages/*.txt missing (and the Containerfile does not take its lists from an octarine-bins image)"
        fi
        # a pinned octarine-bins image needs its digest and tag ARGs (bins-pins.sh verifies and bumps them)
        if grep -qE '^FROM ghcr\.io/redcodeworks/octarine-bins-' "${d}/Containerfile"; then
            grep -qE '^ARG BINS_DIGEST=sha256:[0-9a-f]{64}$' "${d}/Containerfile" || err "${d}/Containerfile: ARG BINS_DIGEST=sha256:<64 hex> missing or malformed"
            grep -qE '^ARG BINS_TAG=[0-9]{8}-[0-9a-f]{7}$' "${d}/Containerfile" || err "${d}/Containerfile: ARG BINS_TAG=<YYYYMMDD>-<sha7> missing or malformed"
            grep -qE '^FROM ghcr\.io/redcodeworks/octarine-bins-(dx|gx)@\$\{BINS_DIGEST\} AS bins$' "${d}/Containerfile" || err "${d}/Containerfile: the bins FROM line must be 'FROM ghcr.io/redcodeworks/octarine-bins-<dx|gx>@\${BINS_DIGEST} AS bins'"
        fi
    fi
    # package lists (required-/optional-<source>.txt as in octarine-bins, or the scaffold's dev.txt): one token per line
    for list in "${lists[@]}"; do
        [[ -e "${list}" ]] || continue
        entries=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${list}")
        [[ -n "${entries}" ]] || err "${list}: no packages"
        bad=$(grep -nE '[[:space:]]' <<<"${entries}" || true)
        [[ -z "${bad}" ]] || err "${list}: more than one token per line: ${bad}"
        badsyntax=$(grep -vE '^(@[A-Za-z0-9._+-]+|[A-Za-z0-9._+-]+(\|[A-Za-z0-9._+-]+)*)$' <<<"${entries}" || true)
        [[ -z "${badsyntax}" ]] || err "${list}: not 'name', '@group' or 'a|b' alternatives: ${badsyntax}"
        while read -r e; do
            [[ -z "${e}" ]] || grep -qxF "${e%.i686}.x86_64" <<<"${entries}" || err "${list}: ${e} needs ${e%.i686}.x86_64 listed explicitly"
        done < <(grep -E '\.i686$' <<<"${entries}" || true)
        dups=$(sort <<<"${entries}" | uniq -d)
        [[ -z "${dups}" ]] || err "${list}: duplicates: ${dups}"
    done
    # This repo builds toolbox images only
    if grep -rIiE 'bootc|ostree|rpm-ostree|kernel-core|bootc-image-builder' "${d}/Containerfile" "${d}"/build_files >/dev/null 2>&1; then
        err "${d}: OS-image parts (bootc/ostree/kernel) found; this repo builds toolbox images only"
    fi
done
dup_names=$(printf '%s\n' "${names[@]}" | sort | uniq -d)
[[ -z "${dup_names}" ]] || err "duplicate image names: ${dup_names}"
[[ ${#names[@]} -gt 0 ]] || err "no image directories (a directory with a Containerfile) found"

# No machine-specific paths or tooling in a public repo (patterns are split so this file does not match itself)
# shellcheck disable=SC2088
local_paths=$(grep -rIn --exclude-dir=.git -e '~/.con''fig' -e '/var/ho''me/' -e 'with-lo''ck.sh' . || true)
[[ -z "${local_paths}" ]] || err "machine-specific paths found (remove or generalise):"$'\n'"${local_paths}"

if (( fail )); then exit 1; fi
echo "lint ok (images: ${names[*]})"
