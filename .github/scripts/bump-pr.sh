#!/usr/bin/env bash
# Open or update the ONE bump pull request of a binary image: branch bump/<image>, into testing.
#
#   bump-pr.sh <image-dir> <new-tag> <new-commit>
#
# Changes only UPSTREAM_TAG and UPSTREAM_COMMIT in <image-dir>/upstream.env. If a PR for exactly this version is already
# open nothing happens. If one for an older version is open, the branch gets one more commit (never a force-push) and
# the PR title and body are updated. Never publishes anything. Needs git (origin = this repository), gh and GH_TOKEN.
# BUMP_TOKEN_SET=true says the token is the BUMP_TOKEN secret (pushes made with it start the test workflow);
# otherwise the PR says that the checks must be started by hand (pushes made with the default GITHUB_TOKEN start nothing).
# Committer identity comes from the environment (the workflow sets it); no commit trailers are added.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../binary-build/upstream-env.sh
source "${here}/../../binary-build/upstream-env.sh"
# shellcheck source=images.sh
source "${here}/images.sh"

dir="${1:?image directory}"
new_tag="${2:?new tag}"
new_commit="${3:?new commit}"
base="${BUMP_BASE:-testing}"
name=$(image_name "${dir}")
branch="bump/${name}"
file="${dir}/upstream.env"

cd "${root}"
upstream_env_load "${file}"
repo="${UPSTREAM_REPO}"
old_tag="${UPSTREAM_TAG}"
old_commit="${UPSTREAM_COMMIT}"
title="Bump ${name} to ${new_tag}"

open=$(gh pr list --head "${branch}" --base "${base}" --state open --json number,title --jq '.[0] // empty')
if [[ -n "${open}" && "$(jq -r .title <<<"${open}")" == "${title}" ]]; then
    echo "A bump PR for ${name} ${new_tag} is already open (#$(jq -r .number <<<"${open}")): nothing to do"
    exit 0
fi

git fetch -q origin
if git rev-parse -q --verify "origin/${branch}" > /dev/null; then
    git checkout -q -B "${branch}" "origin/${branch}"
    git merge -q --no-edit "origin/${base}" || { echo "::error::cannot merge ${base} into ${branch}"; exit 1; }
else
    git checkout -q -B "${branch}" "origin/${base}"
fi
upstream_env_set "${file}" "${new_tag}" "${new_commit}"
git add -- "${file}"
git commit -q -m "Bump ${name} to ${new_tag}: upstream released it; the build checks the tag still resolves to ${new_commit:0:7}"
git push -q origin "refs/heads/${branch}:refs/heads/${branch}"

from=${old_tag:-${old_commit}}
body="Upstream ${repo} has a newer release than the pin of \`${name}\`.

- Pin: \`${old_tag:-commit ${old_commit:0:7}}\` to \`${new_tag}\` (commit \`${new_commit}\`)
- Release notes: https://github.com/${repo}/releases/tag/${new_tag}
- Changes: https://github.com/${repo}/compare/${from}...${new_tag}

Only \`${file}\` changes. The merge into \`${base}\` builds and publishes the \`testing\` image of \`${name}\`; the build fails if the tag does not resolve to the pinned commit. Not verified: nothing is built or run by this PR; a BPF scheduler can only be loaded on a real machine."
if [[ "${BUMP_TOKEN_SET:-false}" != "true" ]]; then
    body+="

The checks did not start on their own: this PR was opened with the default GITHUB_TOKEN, and pushes made with it trigger no workflows. Start them by closing and reopening this PR, or run the \`Test\` workflow on the branch \`${branch}\` (Actions, Run workflow). A repository secret \`BUMP_TOKEN\` (a token limited to this repository with Contents and Pull requests write) makes this automatic."
fi

if [[ -n "${open}" ]]; then
    gh pr edit "$(jq -r .number <<<"${open}")" --title "${title}" --body "${body}"
    echo "Updated the open bump PR #$(jq -r .number <<<"${open}") to ${new_tag}"
else
    gh pr create --base "${base}" --head "${branch}" --title "${title}" --body "${body}"
fi
