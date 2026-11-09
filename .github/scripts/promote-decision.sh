#!/usr/bin/env bash
# Decide for ONE image whether a push to main can PROMOTE an already-tested `testing` image to
# `latest` (retag the same digest, no rebuild) or must build.
#
#   promote-decision.sh <event> <ref> <image-dir> <image-name>
#
# Prints one line: `promote <short sha of C>` or `build <reason>`. Always exits 0 on a decision.
#
# Promote only when it is provably the same content:
#   * event is push, ref is refs/heads/main, and PROMOTE_ENABLED is 'true' (repository variable);
#   * HEAD is a merge commit (two parents) and every file that differs between HEAD and HEAD^2
#     (the testing tip) is docs-only (top-level *.md, docs/**, LICENSE, .gitignore);
#   * walking back the first-parent history of HEAD^2 (at most 50 commits) there is a commit C for
#     which a published `testing-<short sha of C>` tag exists for this image, and every file changed
#     between C and HEAD^2 is docs-only or lives in another image's directory (the image's own
#     EXTRA_PATHS directories from image.env, such as dev-packages for dev-toolbox, do not count as another's).
# Anything else builds (schedule, dispatch, non-merge push, differing trees, no matching image).
#
# The registry lookup is `${TAG_EXISTS_CMD:-registry_has_tag} <image-name> <tag>` (exit 0 = exists);
# the default asks ghcr.io with skopeo. REPO_ROOT overrides the repository root (tests).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=images.sh
source "${here}/images.sh"

event="${1:?event}"
ref="${2:?ref}"
dir="${3:?image dir}"
name="${4:?image name}"

build() { echo "build $*"; exit 0; }

registry_has_tag() { # name tag
    skopeo inspect --raw "docker://${IMAGE_REGISTRY:?IMAGE_REGISTRY}/${1,,}:$2" >/dev/null 2>&1
}
tag_exists() { "${TAG_EXISTS_CMD:-registry_has_tag}" "$1" "$2"; }

is_docs_only() {
    case "$1" in
        */*) [[ "$1" == docs/* ]] ;;
        *.md | LICENSE | .gitignore) return 0 ;;
        *) return 1 ;;
    esac
}

g() { git -C "${root}" "$@"; }

[[ "${event}" == "push" && "${ref}" == "refs/heads/main" ]] || build "not a push to main (${event} ${ref})"
[[ "${PROMOTE_ENABLED:-}" == "true" ]] || build "PROMOTE_ENABLED is not true"

parents=$(g rev-list --parents -n1 HEAD | wc -w)
(( parents == 3 )) || build "HEAD is not a merge commit"

while IFS= read -r f; do
    is_docs_only "${f}" || build "trees differ (${f} differs between main and the testing tip)"
done < <(g diff --name-only HEAD HEAD^2)

tip=$(g rev-parse HEAD^2)
others=()
own=" ${dir} $(image_extra_paths "${dir}") "
for d in $(image_dirs); do [[ "${own}" == *" ${d} "* ]] || others+=("${d}"); done

found=""
while IFS= read -r c; do
    if tag_exists "${name}" "testing-${c:0:7}"; then
        found="${c}"
        break
    fi
done < <(g rev-list --first-parent -n 50 "${tip}")
[[ -n "${found}" ]] || build "no published testing image found for ${name}"

while IFS= read -r f; do
    is_docs_only "${f}" && continue
    for o in "${others[@]}"; do
        [[ "${f}" == "${o}/"* ]] && continue 2
    done
    build "${f} changed after the tested image (${found:0:7})"
done < <(g diff --name-only "${found}" "${tip}")

echo "promote ${found:0:7}"
