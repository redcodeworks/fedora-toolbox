#!/usr/bin/env bash
# Image discovery. Every top-level directory that contains a Containerfile is one image.
# The image name is the directory name unless <dir>/image.env sets IMAGE_NAME.
#
#   images.sh list            one line per image: <dir><TAB><name><TAB><description>
#   images.sh json            {"include":[{"image":"<name>","dir":"<dir>"}, ...]}
#   images.sh resolve <x>     "<dir> <name>" for an image given by directory or name (error if unknown)
#
# Can also be sourced (image_dirs, image_name, image_desc, image_json). REPO_ROOT overrides the
# repository root (the tests use that).
set -euo pipefail

root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

image_dirs() {
    local f
    for f in "${root}"/*/Containerfile; do
        [[ -e "${f}" ]] || continue
        basename "$(dirname "${f}")"
    done
}

_env_var() { # dir var
    local file="${root}/$1/image.env"
    [[ -f "${file}" ]] || return 0
    sed -n "s/^$2=//p" "${file}" | tr -d "\"'" | head -n1
}

image_name() {
    local n
    n=$(_env_var "$1" IMAGE_NAME)
    echo "${n:-$1}"
}

image_desc() { _env_var "$1" IMAGE_DESC; }

image_json() {
    local d out="" sep=""
    for d in $(image_dirs); do
        out+="${sep}{\"image\":\"$(image_name "${d}")\",\"dir\":\"${d}\"}"
        sep=","
    done
    printf '{"include":[%s]}\n' "${out}"
}

resolve_image() {
    local d
    for d in $(image_dirs); do
        if [[ "$1" == "${d}" || "$1" == "$(image_name "${d}")" ]]; then
            echo "${d} $(image_name "${d}")"
            return 0
        fi
    done
    echo "unknown image '$1' (images: $(image_dirs | tr '\n' ' '))" >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        list)
            for d in $(image_dirs); do printf '%s\t%s\t%s\n' "${d}" "$(image_name "${d}")" "$(image_desc "${d}")"; done
            ;;
        json) image_json ;;
        resolve) resolve_image "${2:?image}" ;;
        *) echo "usage: images.sh list|json|resolve <image>" >&2; exit 2 ;;
    esac
fi
