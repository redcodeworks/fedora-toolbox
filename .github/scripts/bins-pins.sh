#!/usr/bin/env bash
# The pins of the octarine-bins images (octarine-bins-dx, octarine-bins-gx) that the toolbox Containerfiles take their package lists and installer from.
# A Containerfile pins one image by digest:
#
#   ARG BINS_TAG=<YYYYMMDD>-<sha7>        (the newest dated registry tag of that digest, for humans)
#   ARG BINS_DIGEST=sha256:<64 hex>
#   FROM ghcr.io/redcodeworks/octarine-bins-<dx|gx>@${BINS_DIGEST} AS bins
#
#   bins-pins.sh verify <image-dir>   check the pinned digest with keys/octarine-bins.pub (the build runs this before it builds)
#   bins-pins.sh bump <dx|gx>         resolve octarine-bins-<kind>:latest, verify it with keys/octarine-bins.pub and write tag and digest into every
#                                     Containerfile that pins that image (nothing is written when the digest or the signature does not check out).
#                                     The tag is the newest registry tag matching <YYYYMMDD>-<sha7> whose manifest digest is the pinned one (the
#                                     image carries no version label since octarine-bins #29; an old image that still has one is not consulted).
#
# Needs skopeo, cosign and jq (bump). REPO_ROOT overrides the repository root (tests); BINS_REGISTRY the registry path (tests).
set -euo pipefail

root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
registry="${BINS_REGISTRY:-ghcr.io/redcodeworks}"
key="${root}/keys/octarine-bins.pub"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "bins-pins.sh: $*" >&2; exit 1; }

# the Containerfiles that pin octarine-bins-<kind>
pinned_by() { grep -lE "^FROM [^ ]*octarine-bins-$1@" "${root}"/*/Containerfile 2> /dev/null || true; }

cmd=${1:-}
case "${cmd}" in
    verify)
        dir=${2:?image dir}
        cf="${root}/${dir}/Containerfile"
        kind=$(sed -n 's#^FROM [^ ]*octarine-bins-\([a-z]*\)@.*#\1#p' "${cf}" | head -n1)
        [[ -n "${kind}" ]] || { echo "${dir}: pins no octarine-bins image, nothing to verify"; exit 0; }
        digest=$(sed -n 's/^ARG BINS_DIGEST=//p' "${cf}")
        [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "BINS_DIGEST in ${cf} is missing or malformed"
        ref="${registry}/octarine-bins-${kind}@${digest}"
        cosign verify --key "${key}" "${ref}" > /dev/null || die "the signature of ${ref} does not verify with keys/octarine-bins.pub"
        echo "${dir}: ${ref} (tag $(sed -n 's/^ARG BINS_TAG=//p' "${cf}")) signature valid"
        ;;
    bump)
        kind=${2:?dx or gx}
        [[ "${kind}" == dx || "${kind}" == gx ]] || die "the kind is dx or gx"
        ref="${registry}/octarine-bins-${kind}"
        digest=$(skopeo inspect --raw "docker://${ref}:latest" | sha256sum | sed 's/ .*//')
        [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || die "cannot resolve ${ref}:latest"
        cosign verify --key "${key}" "${ref}@sha256:${digest}" > /dev/null || die "cosign verification failed for ${ref}@sha256:${digest}; nothing changed"
        # build identity lives in the registry tags: the newest dated tag that points at this digest (a byte-identical rebuild adds a tag, not a digest)
        version=""
        while read -r t; do
            raw=$(mktemp)
            if "${here}/retry.sh" skopeo inspect --raw "docker://${ref}:${t}" > "${raw}"; then
                [[ "$(sha256sum < "${raw}" | sed 's/ .*//')" == "${digest}" ]] && version=${t}
            else
                echo "bins-pins.sh: cannot read ${ref}:${t}, skipping it" >&2
            fi
            rm -f "${raw}"
            [[ -z "${version}" ]] || break
        done < <("${here}/retry.sh" skopeo list-tags "docker://${ref}" | jq -r '.Tags[]' | grep -E '^[0-9]{8}-[0-9a-f]{7}$' | sort -r)
        [[ -n "${version}" ]] || die "no tag of the form <YYYYMMDD>-<sha7> in ${ref} points at sha256:${digest}; nothing changed"
        mapfile -t files < <(pinned_by "${kind}")
        [[ ${#files[@]} -gt 0 ]] || die "no Containerfile pins octarine-bins-${kind}"
        for f in "${files[@]}"; do
            sed -i -e "s/^ARG BINS_TAG=.*/ARG BINS_TAG=${version}/" -e "s/^ARG BINS_DIGEST=.*/ARG BINS_DIGEST=sha256:${digest}/" "${f}"
            echo "${f#"${root}"/} now pins ${ref}:${version}@sha256:${digest} (signature valid)"
        done
        ;;
    *) echo "usage: bins-pins.sh verify <image-dir> | bump <dx|gx>" >&2; exit 2 ;;
esac
