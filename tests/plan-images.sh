#!/usr/bin/env bash
# Tests for .github/scripts/plan-images.sh and images.sh in a throwaway git repository with two
# images (alpha, and beta whose image.env renames it to beta-image) and one non-image directory.
# No network. Needs: bash, git, python3. Run: tests/plan-images.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
repo="${tmp}/repo"
mkdir -p "${repo}/.github/scripts" "${repo}/alpha" "${repo}/beta" "${repo}/docs"
cp "${src}/.github/scripts/images.sh" "${src}/.github/scripts/plan-images.sh" "${repo}/.github/scripts/"
echo "FROM scratch" > "${repo}/alpha/Containerfile"
echo "FROM scratch" > "${repo}/beta/Containerfile"
echo 'IMAGE_NAME=beta-image' > "${repo}/beta/image.env"
echo docs > "${repo}/docs/a.md"
echo readme > "${repo}/README.md"
echo just > "${repo}/Justfile"
echo '{}' > "${repo}/.github/renovate.json5"
plan="${repo}/.github/scripts/plan-images.sh"

g() { git -C "${repo}" -c user.name=t -c user.email=t@example.invalid "$@"; }
g init -q -b main
g add -A
g commit -q -m base
base=$(g rev-parse HEAD)

commit_change() { # file -> prints the new commit sha, from the current HEAD
    mkdir -p "$(dirname "${repo}/$1")"
    echo "$RANDOM" >> "${repo}/$1"
    g add -A
    g commit -q -m "change $1"
    g rev-parse HEAD
}

# names <expected> <description> <plan args...>   ("-" means none, "ERROR" means failure)
names() {
    local want=$1 d=$2 out got
    shift 2
    if ! out=$("${plan}" "$@" 2>/dev/null); then
        got=ERROR
    else
        got=$(python3 -I -c 'import json,sys; print(" ".join(e["image"] for e in json.loads(sys.argv[1])["include"]) or "-")' "${out}") || got=BADJSON
    fi
    if [[ "${got}" == "${want}" ]]; then ok "${d}"; else bad "${d} (want '${want}', got '${got}')"; fi
}

zeros=0000000000000000000000000000000000000000

# Image discovery: directory name, image.env override, non-image directory ignored
list=$(REPO_ROOT="${repo}" "${repo}/.github/scripts/images.sh" list | cut -f1,2 | tr '\t\n' ': ')
if [[ "${list}" == "alpha:alpha beta:beta-image " ]]; then ok "images: directory name by default, image.env overrides, docs/ ignored"; else bad "image list: ${list}"; fi

c1=$(commit_change alpha/packages/x.txt)
names "alpha" "only alpha changed: alpha" push "${base}" "${c1}"
c2=$(commit_change beta/build_files/b.sh)
names "beta-image" "only beta changed: beta (named by image.env)" push "${c1}" "${c2}"
names "alpha beta-image" "range over both: both" push "${base}" "${c2}"
c3=$(commit_change README.md)
names "-" "README only: nothing to build" push "${c2}" "${c3}"
c4=$(commit_change docs/b.md)
names "-" "non-image directory only: nothing to build" push "${c3}" "${c4}"
c5=$(commit_change .github/renovate.json5)
names "-" "renovate config only does not count as shared" push "${c4}" "${c5}"
names "-" "no changes (before equals after): nothing" push "${c5}" "${c5}"
names "alpha" "pull_request uses the same range rules" pull_request "${base}" "${c1}"

c6=$(commit_change .github/workflows/build.yml)
names "alpha beta-image" "workflow file changed: all" push "${c5}" "${c6}"
c7=$(commit_change Justfile)
names "alpha beta-image" "root Justfile changed: all" push "${c6}" "${c7}"
c8=$(commit_change .github/scripts/lint.sh)
names "alpha beta-image" "shared script changed: all" pull_request "${c7}" "${c8}"
c9=$(commit_change cosign.pub)
names "alpha beta-image" "cosign.pub changed: all" push "${c8}" "${c9}"
# a change to one image plus a shared file: all
names "alpha beta-image" "image plus shared file: all" push "${c4}" "${c7}"

# Before-SHA unusable: build all
names "alpha beta-image" "new branch (all-zero before): all" push "${zeros}" "${c9}"
names "alpha beta-image" "unknown before sha: all" push "1111111111111111111111111111111111111111" "${c9}"
names "alpha beta-image" "empty before: all" push "" "${c9}"

# Schedule and manual runs
names "alpha beta-image" "weekly schedule: all" schedule "" ""
names "alpha beta-image" "workflow_dispatch without image: all" workflow_dispatch "" "" ""
names "beta-image" "workflow_dispatch with image name: that image" workflow_dispatch "" "" beta-image
names "beta-image" "workflow_dispatch with directory name: that image" workflow_dispatch "" "" beta
names "alpha" "workflow_dispatch image=alpha: alpha" workflow_dispatch "" "" alpha
names "ERROR" "workflow_dispatch with unknown image fails" workflow_dispatch "" "" nope
names "ERROR" "unknown event fails" release "" ""

# A removed image directory is not built
g rm -q -r alpha
g commit -q -m "remove alpha"
c10=$(g rev-parse HEAD)
names "-" "removed image directory: not built" push "${c9}" "${c10}"
names "beta-image" "after removal, schedule builds only what exists" schedule "" ""

# The real repo: the image the host recipe depends on keeps its published name
real=$(REPO_ROOT="${src}" "${src}/.github/scripts/images.sh" list | cut -f1,2 | tr '\t\n' ' ')
case "${real}" in
    *"fedora-toolbox fedora-toolbox"*) ok "real repo: fedora-toolbox/ publishes as fedora-toolbox" ;;
    *) bad "real repo image list: ${real}" ;;
esac

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
