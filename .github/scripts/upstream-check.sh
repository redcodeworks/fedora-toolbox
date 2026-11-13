#!/usr/bin/env bash
# Ask upstream whether a binary image has something newer than its pin, and print ONE decision line:
#
#   upstream-check.sh <image-dir>
#
#   current <what>             nothing newer (pinned tag is the latest release, or the pin is ahead of it)
#   bump <tag> <commit>        a newer release exists: <tag> and the commit it resolves to (peeled for annotated tags)
#   report <text>              commit-pinned project without a release or tag ahead of the pin: nothing to open
#   unreachable <text>         upstream could not be asked; fail soft (exit 0), the next weekly run tries again
#
# Reads upstream.env (UPSTREAM_REPO, UPSTREAM_TAG, UPSTREAM_COMMIT). Tag pin: the latest release (not a draft or
# pre-release) is newer when it sorts above the pinned tag by version. Commit pin (empty UPSTREAM_TAG): the latest
# release, else the newest tag, counts only when its commit is AHEAD of the pinned commit (the compare API), so an
# older release than the pin is never "newer". Only `gh api` reads; nothing is written.
# shellcheck disable=SC2015  # the `A && B || C` form is used on purpose: C is the fail-soft answer
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../binary-build/upstream-env.sh
source "${here}/../../binary-build/upstream-env.sh"
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"

dir="${1:?image directory}"
upstream_env_load "${root}/${dir}/upstream.env" || { echo "unreachable invalid ${dir}/upstream.env"; exit 0; }
repo="${UPSTREAM_REPO}"

latest=$(gh api "repos/${repo}/releases/latest" --jq .tag_name 2> /dev/null) || latest=""
if [[ -z "${latest}" && -z "${UPSTREAM_TAG}" ]]; then
    # a commit-pinned project may have tags but no release object
    if ! tags=$(gh api "repos/${repo}/tags" --jq '.[0].name // ""' 2> /dev/null); then
        echo "unreachable cannot read releases or tags of ${repo}"
        exit 0
    fi
    latest=${tags}
fi
if [[ -z "${latest}" ]]; then
    if [[ -n "${UPSTREAM_TAG}" ]]; then echo "unreachable cannot read the latest release of ${repo}"; else echo "report ${repo} has no release or tag; pinned at ${UPSTREAM_COMMIT:0:7}"; fi
    exit 0
fi

commit_of() { gh api "repos/${repo}/commits/$1" --jq .sha 2> /dev/null; }

if [[ -n "${UPSTREAM_TAG}" ]]; then
    if [[ "${latest}" == "${UPSTREAM_TAG}" ]]; then echo "current ${UPSTREAM_TAG} is the latest release"; exit 0; fi
    top=$(printf '%s\n%s\n' "${UPSTREAM_TAG}" "${latest}" | sort -V | tail -n1)
    if [[ "${top}" != "${latest}" ]]; then echo "current pinned ${UPSTREAM_TAG} is ahead of the latest release ${latest}"; exit 0; fi
    commit=$(commit_of "${latest}") && [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "unreachable cannot resolve ${repo} ${latest} to a commit"; exit 0; }
    echo "bump ${latest} ${commit}"
    exit 0
fi

commit=$(commit_of "${latest}") && [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "unreachable cannot resolve ${repo} ${latest} to a commit"; exit 0; }
status=$(gh api "repos/${repo}/compare/${UPSTREAM_COMMIT}...${commit}" --jq .status 2> /dev/null) || { echo "unreachable cannot compare ${repo} ${UPSTREAM_COMMIT:0:7} with ${latest}"; exit 0; }
case "${status}" in
    ahead) echo "bump ${latest} ${commit}" ;;
    identical) echo "current the pinned commit is ${latest}" ;;
    *) echo "report latest release ${latest} is ${status} of the pinned commit ${UPSTREAM_COMMIT:0:7}; nothing to bump" ;;
esac
