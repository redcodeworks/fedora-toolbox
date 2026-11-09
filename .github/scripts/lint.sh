#!/usr/bin/env bash
# Lint the repo: script syntax (and shellcheck if installed), the layout of every image directory,
# the package lists, unique image names, and the "toolbox images only" rule (no OS-image parts).
# REPO_ROOT overrides the repository root (the scaffold test lints a temporary copy).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=images.sh
source "${here}/images.sh"
cd "${root}"

fail=0
err() { echo "lint: $*" >&2; fail=1; }

shopt -s nullglob
scripts=(.github/scripts/*.sh tests/*.sh ./*/build_files/*.sh ./*/tests/*.sh ./*/stack/bin/* ./*/bin/*)
bash -n "${scripts[@]}" || fail=1
if command -v shellcheck >/dev/null; then
    shellcheck -x -P SCRIPTDIR "${scripts[@]}" || fail=1
else
    echo "shellcheck not installed, skipping"
fi

names=()
for d in $(image_dirs); do
    n=$(image_name "${d}")
    [[ "${n}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || err "${d}: image name '${n}' must be lowercase (a-z, 0-9, . _ -)"
    names+=("${n}")
    grep -qE '^FROM ' "${d}/Containerfile" || err "${d}/Containerfile has no FROM line"
    [[ -x "${d}/tests/smoke.sh" ]] || err "${d}/tests/smoke.sh missing or not executable"
    # IMAGE_KIND=app (in <dir>/image.env): an application image of the dna stack (Connect, Airflow,
    # Superset) built from its own Containerfile: no toolbox base, build.sh or package list required.
    kind=$({ sed -n 's/^IMAGE_KIND=//p' "${d}/image.env" 2>/dev/null || true; } | tr -d "\"'" | head -n1)
    if [[ "${kind}" == "app" ]]; then
        if grep -rIiE 'bootc|ostree|rpm-ostree|kernel-core|bootc-image-builder' "${d}/Containerfile" >/dev/null; then
            err "${d}: OS-image parts (bootc/ostree/kernel) found; this repo builds toolbox and app images only"
        fi
        continue
    fi
    [[ -f "${d}/build_files/build.sh" ]] || err "${d}/build_files/build.sh missing"
    lists=("${d}"/packages/*.txt)
    [[ ${#lists[@]} -gt 0 ]] || err "${d}/packages/*.txt missing"
    for list in "${lists[@]}"; do
        entries=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${list}")
        [[ -n "${entries}" ]] || err "${list}: no packages"
        bad=$(grep -nE '[[:space:]]' <<<"${entries}" || true)
        [[ -z "${bad}" ]] || err "${list}: more than one token per line: ${bad}"
        dups=$(sort <<<"${entries}" | uniq -d)
        [[ -z "${dups}" ]] || err "${list}: duplicates: ${dups}"
    done
    # This repo builds toolbox images only
    if grep -rIiE 'bootc|ostree|rpm-ostree|kernel-core|bootc-image-builder' "${d}/Containerfile" "${d}/build_files" >/dev/null; then
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
