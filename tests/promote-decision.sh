#!/usr/bin/env bash
# Tests for .github/scripts/promote-decision.sh and plan-promote.sh in throwaway git repositories
# with two images (alpha, beta) and a fake registry (a file of "<image> <tag>" lines).
# No network. Needs: bash, git, python3. Run: tests/promote-decision.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

reg="${tmp}/registry"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ngrep -qxF "$1 $2" "%s"\n' "${reg}" > "${tmp}/fake-tag-exists"
chmod +x "${tmp}/fake-tag-exists"

n=0
newrepo() { # -> sets $repo with base commit on main, branch testing at the same commit
    n=$((n + 1))
    repo="${tmp}/repo${n}"
    mkdir -p "${repo}/.github/scripts" "${repo}/alpha" "${repo}/beta" "${repo}/docs"
    cp "${src}/.github/scripts/images.sh" "${src}/.github/scripts/promote-decision.sh" "${src}/.github/scripts/plan-promote.sh" "${repo}/.github/scripts/"
    echo "FROM scratch" > "${repo}/alpha/Containerfile"
    echo "FROM scratch" > "${repo}/beta/Containerfile"
    echo readme > "${repo}/README.md"
    : > "${reg}"
    git -C "${repo}" init -q -b main
    git -C "${repo}" add -A
    gt commit -q -m base
    git -C "${repo}" branch testing
}
gt() { git -C "${repo}" -c user.name=t -c user.email=t@example.invalid "$@"; }
change() { # file -> commit on the current branch, prints the sha
    mkdir -p "$(dirname "${repo}/$1")"
    echo "$RANDOM" >> "${repo}/$1"
    gt add -A
    gt commit -q -m "change $1"
    gt rev-parse HEAD
}
published() { echo "$1 testing-${2:0:7}" >> "${reg}"; } # image sha
decide() { # want desc event ref image [env...]
    local want=$1 d=$2 ev=$3 ref=$4 img=$5 got
    got=$(REPO_ROOT="${repo}" TAG_EXISTS_CMD="${tmp}/fake-tag-exists" PROMOTE_ENABLED="${PROMOTE_ENABLED-true}" \
        "${repo}/.github/scripts/promote-decision.sh" "${ev}" "${ref}" "${img}" "${img}" 2>&1)
    if [[ "${got}" == "${want}"* ]]; then ok "${d}"; else bad "${d} (want '${want}...', got '${got}')"; fi
}
merge_testing() { gt checkout -q main; gt merge -q --no-ff -m "Merge testing" testing; }

# 1. merge with equal trees: promote the tested commit
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; merge_testing
decide "promote ${t1:0:7}" "merge, equal trees, tested image: promote" push refs/heads/main alpha

# 2. extra commit on main before the merge: trees differ
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"
gt checkout -q main; change alpha/onmain.txt >/dev/null; merge_testing
decide "build trees differ" "merge with an extra commit on main: build" push refs/heads/main alpha

# 2b. extra docs-only commit on main: still the same image content
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"
gt checkout -q main; change README.md >/dev/null; merge_testing
decide "promote ${t1:0:7}" "extra docs-only commit on main: still promote" push refs/heads/main alpha

# 3. non-merge push to main
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; gt checkout -q main; gt merge -q --ff-only testing
decide "build HEAD is not a merge commit" "fast-forward (non-merge) push: build" push refs/heads/main alpha

# 4. testing tip is a docs-only commit; the image is behind it
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; change README.md >/dev/null; change docs/x.md >/dev/null; merge_testing
decide "promote ${t1:0:7}" "docs-only commits after the tested image: promote the older image" push refs/heads/main alpha

# 5. only another image's directory changed since C
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; change beta/b.txt >/dev/null; merge_testing
decide "promote ${t1:0:7}" "only beta changed since alpha's image: promote alpha" push refs/heads/main alpha
decide "build no published testing image found for beta" "beta has no published image: build" push refs/heads/main beta

# 5b. the same image directory changed after C
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; change alpha/c.txt >/dev/null; merge_testing
decide "build alpha/c.txt changed after the tested image" "alpha changed after its tested image: build" push refs/heads/main alpha

# 5c. a shared file changed after C
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; change .github/workflows/build.yml >/dev/null; merge_testing
decide "build .github/workflows/build.yml changed after" "shared file changed after the tested image: build" push refs/heads/main alpha

# 6. no image found
newrepo; gt checkout -q testing; change alpha/a.txt >/dev/null; merge_testing
decide "build no published testing image found for alpha" "no testing image: build" push refs/heads/main alpha

# 6b. an image published for a commit that is not on the testing side does not count
newrepo; gt checkout -q testing; change alpha/a.txt >/dev/null; echo "alpha testing-0000000" >> "${reg}"; merge_testing
decide "build no published testing image found for alpha" "unrelated tag: build" push refs/heads/main alpha

# 7. other triggers and the gate (repo of case 1)
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; merge_testing
decide "build not a push to main" "schedule: build" schedule refs/heads/main alpha
decide "build not a push to main" "workflow_dispatch: build" workflow_dispatch refs/heads/main alpha
decide "build not a push to main" "push to testing: build" push refs/heads/testing alpha
PROMOTE_ENABLED="" decide "build PROMOTE_ENABLED is not true" "PROMOTE_ENABLED empty: build" push refs/heads/main alpha
PROMOTE_ENABLED="false" decide "build PROMOTE_ENABLED is not true" "PROMOTE_ENABLED false: build" push refs/heads/main alpha
got=$(env -u PROMOTE_ENABLED REPO_ROOT="${repo}" TAG_EXISTS_CMD="${tmp}/fake-tag-exists" "${repo}/.github/scripts/promote-decision.sh" push refs/heads/main alpha alpha)
if [[ "${got}" == "build PROMOTE_ENABLED is not true" ]]; then ok "PROMOTE_ENABLED unset: build"; else bad "PROMOTE_ENABLED unset (got '${got}')"; fi

# 8. plan-promote.sh: one image can be promoted while another is rebuilt
newrepo; gt checkout -q testing; t1=$(change alpha/a.txt); published alpha "${t1}"; merge_testing
matrix='{"include":[{"image":"alpha","dir":"alpha"},{"image":"beta","dir":"beta"}]}'
out=$(REPO_ROOT="${repo}" TAG_EXISTS_CMD="${tmp}/fake-tag-exists" PROMOTE_ENABLED=true "${repo}/.github/scripts/plan-promote.sh" "${matrix}" push refs/heads/main)
if python3 -I -c 'import json,sys
e={x["image"]:x for x in json.loads(sys.argv[1])["include"]}
sys.exit(not (e["alpha"]["mode"]=="promote" and e["alpha"]["source"]==sys.argv[2] and e["beta"]["mode"]=="build" and e["beta"]["source"]=="" and e["beta"]["reason"]))' "${out}" "${t1:0:7}"; then
    ok "plan-promote: alpha promoted, beta rebuilt in the same run"
else
    bad "plan-promote output: ${out}"
fi
out=$(REPO_ROOT="${repo}" TAG_EXISTS_CMD="${tmp}/fake-tag-exists" PROMOTE_ENABLED=true "${repo}/.github/scripts/plan-promote.sh" '{"include":[]}' push refs/heads/main)
if [[ "${out}" == '{"include":[]}' ]]; then ok "plan-promote: empty plan stays empty"; else bad "empty plan: ${out}"; fi

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
