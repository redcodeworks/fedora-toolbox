#!/usr/bin/env bash
# Image discovery. Every top-level directory that contains a Containerfile is one image.
# The image name is the directory name unless <dir>/image.env sets IMAGE_NAME.
#
#   images.sh list            one line per image: <dir><TAB><name><TAB><description>
#   images.sh json            {"include":[{"image":"<name>","dir":"<dir>"}, ...]}
#   images.sh resolve <x>     "<dir> <name>" for an image given by directory or name (error if unknown)
#   images.sh context <dir>   the build context of an image directory (default: the directory)
#   images.sh data-files <dir>  the <repo path>:<image path> pairs a list image must carry (image.env DATA_FILES)
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

# IMAGE_KIND=list marks a data image (FROM scratch: the shared package list), "toolbox" is the default
image_kind() { local k; k=$(_env_var "$1" IMAGE_KIND); echo "${k:-toolbox}"; }

# Build context directory, relative to the repository root (default: the image directory itself;
# BUILD_CONTEXT=. makes the whole repository the context, the Containerfile then names its paths)
image_context() { local c; c=$(_env_var "$1" BUILD_CONTEXT); echo "${c:-$1}"; }

# Other top-level directories whose files belong to this image (EXTRA_PATHS, space separated): a change
# there rebuilds this image and is never "another image's directory" for the promote decision
image_extra_paths() { _env_var "$1" EXTRA_PATHS; }

# IMAGE_SCHEDULE=false: the weekly schedule does not rebuild this image
image_scheduled() { [[ "$(_env_var "$1" IMAGE_SCHEDULE)" != "false" ]]; }

# DATA_FILES (list images): "<repo path>:<path in the image>" pairs, space separated; the build compares them
image_data_files() { _env_var "$1" DATA_FILES | tr ' ' '\n' | sed '/^$/d'; }

image_json() { # [scheduled]: with an argument, leave out the images with IMAGE_SCHEDULE=false
    local d out="" sep=""
    for d in $(image_dirs); do
        if [[ -n "${1:-}" ]] && ! image_scheduled "${d}"; then continue; fi
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
        context) image_context "${2:?dir}" ;;
        data-files) image_data_files "${2:?dir}" ;;
        *) echo "usage: images.sh list|json|resolve <image>|context <dir>|data-files <dir>" >&2; exit 2 ;;
    esac
fi
