#!/usr/bin/env bash
# Decide which images a workflow run builds and print the matrix as one line of JSON.
#
#   plan-images.sh <event> [<before> [<after> [<dispatch-image>]]]
#
# <event>           github.event_name
# <before>/<after>  the commit range to diff: github.event.before and github.sha for pushes, the
#                   base and head commits for pull requests (after defaults to HEAD)
# <dispatch-image>  optional `image` input of a manual run (directory or image name)
#
# Rules:
#   schedule                 build all images
#   workflow_dispatch        build all images, or only the one named
#   push, pull_request       build the images whose directory has changed files in <before>..<after>;
#                            a change to a shared file (anything under .github/ except renovate and
#                            dependabot config, the root Justfile, cosign.pub) builds all images;
#                            an empty, all-zero or unknown <before> (new branch, force push) builds all
# An empty list ({"include":[]}) means nothing to build; the workflow then skips the build jobs and
# its aggregate checks still pass. No workflow-level `paths:` filter is used, because required status
# checks of a skipped workflow stay pending forever.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=images.sh
source "${here}/images.sh"

event="${1:?event}"
before="${2-}"
after="${3:-HEAD}"
want="${4-}"

all() { image_json; }

json_for() { # dirs...
    local d out="" sep=""
    for d in "$@"; do
        out+="${sep}{\"image\":\"$(image_name "${d}")\",\"dir\":\"${d}\"}"
        sep=","
    done
    printf '{"include":[%s]}\n' "${out}"
}

is_shared() {
    case "$1" in
        .github/renovate.json5 | .github/dependabot.yml) return 1 ;;
        .github/* | Justfile | cosign.pub) return 0 ;;
    esac
    return 1
}

case "${event}" in
    schedule) all ;;
    workflow_dispatch)
        if [[ -n "${want}" ]]; then
            read -r d _ < <(resolve_image "${want}") || exit 1
            json_for "${d}"
        else
            all
        fi
        ;;
    push | pull_request)
        if [[ -z "${before}" || "${before}" =~ ^0+$ ]] \
            || ! git -C "${root}" cat-file -e "${before}^{commit}" 2>/dev/null \
            || ! git -C "${root}" cat-file -e "${after}^{commit}" 2>/dev/null; then
            echo "no usable base commit ('${before}'): building all images" >&2
            all
            exit 0
        fi
        mapfile -t changed < <(git -C "${root}" diff --name-only "${before}" "${after}")
        for f in "${changed[@]}"; do
            if is_shared "${f}"; then
                echo "shared file changed (${f}): building all images" >&2
                all
                exit 0
            fi
        done
        picked=()
        for d in $(image_dirs); do
            for f in "${changed[@]}"; do
                if [[ "${f}" == "${d}/"* ]]; then
                    picked+=("${d}")
                    break
                fi
            done
        done
        json_for "${picked[@]}"
        ;;
    *) echo "unknown event '${event}'" >&2; exit 1 ;;
esac
