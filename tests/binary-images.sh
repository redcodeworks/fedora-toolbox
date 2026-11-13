#!/usr/bin/env bash
# Tests for the binary images (scx-bin, extest-bin; IMAGE_KIND=binary): discovery, planning, the upstream.env parser,
# the commit-SHA verification of the checkout, the scratch layout, the weekly upstream check (equal, newer, bump PR
# already open, upstream unreachable) and the workflow triggers. Local git repositories and a stub gh; no network.
# Needs: bash, git, python3 with PyYAML, readelf and ldd (binutils, libc). Run: tests/binary-images.sh
# shellcheck disable=SC2015,SC2016
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
images="${src}/.github/scripts/images.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

sha() { local s='' i; for i in {1..40}; do s+=$1; done; echo "${s}"; }

# --- discovery, kind, schedule, tags
list=$(REPO_ROOT="${src}" "${images}" list | cut -f1,2 | tr '\t\n' ' ')
for n in scx-bin extest-bin; do [[ "${list}" == *"${n} ${n} "* ]] && ok "image listed: ${n}" || bad "image list lacks ${n}"; done
[[ "$(REPO_ROOT="${src}" "${images}" dirs binary | tr '\n' ' ')" == "extest-bin scx-bin " ]] && ok "dirs binary lists the two binary images" || bad "dirs binary"
[[ "$(REPO_ROOT="${src}" "${images}" kind scx-bin)" == binary ]] && ok "kind: binary" || bad "kind"
sched=$(REPO_ROOT="${src}" "${src}/.github/scripts/plan-images.sh" schedule)
for n in scx-bin extest-bin; do [[ "${sched}" != *"\"${n}\""* ]] && ok "the weekly schedule leaves ${n} out" || bad "the weekly schedule rebuilds ${n}"; done
[[ "$(REPO_ROOT="${src}" "${images}" version-tag scx-bin)" == "v1.1.4" ]] && ok "version tag of a tag pin is the upstream tag" || bad "scx version tag: $(REPO_ROOT="${src}" "${images}" version-tag scx-bin)"
[[ "$(REPO_ROOT="${src}" "${images}" version-tag extest-bin)" == "commit-cb77cd4" ]] && ok "version tag of a commit pin is commit-<sha7>" || bad "extest version tag"
[[ "$(REPO_ROOT="${src}" "${images}" binary-files scx-bin | tr '\n' ' ')" == "bin/scx_rusty bin/scx_lavd " ]] && ok "scx-bin must carry bin/scx_rusty and bin/scx_lavd" || bad "scx binary files"
[[ "$(REPO_ROOT="${src}" "${images}" binary-files extest-bin)" == "lib64/libextest.so" ]] && ok "extest-bin must carry lib64/libextest.so" || bad "extest binary files"

# --- pins and build commands of the real images
# shellcheck source=/dev/null
. "${src}/binary-build/upstream-env.sh"
upstream_env_load "${src}/scx-bin/upstream.env" && [[ "${UPSTREAM_REPO}" == sched-ext/scx && -n "${UPSTREAM_TAG}" ]] && ok "scx-bin pins a tag of sched-ext/scx" || bad "scx upstream.env"
upstream_env_load "${src}/extest-bin/upstream.env" && [[ "${UPSTREAM_REPO}" == Supreeeme/extest && -z "${UPSTREAM_TAG}" && "${UPSTREAM_COMMIT}" == cb77cd4f80f83393a24bae17dd975e14fa6eb1b2 ]] && ok "extest-bin pins the commit cb77cd4f, no tag" || bad "extest upstream.env"
grep -qx 'RUN cargo build --release --locked -p scx_rusty -p scx_lavd' "${src}/scx-bin/Containerfile" && ok "scx-bin builds both schedulers from one tag with --locked" || bad "scx cargo command"
grep -qx 'RUN cargo build --release --locked --target x86_64-unknown-linux-gnu' "${src}/extest-bin/Containerfile" && ok "extest-bin builds like the octarine-os recipe (--locked, x86_64 target)" || bad "extest cargo command"
grep -q 'target/x86_64-unknown-linux-gnu/release/libextest.so:lib64/libextest.so' "${src}/extest-bin/Containerfile" && ok "extest-bin installs target/x86_64-unknown-linux-gnu/release/libextest.so as lib64/libextest.so" || bad "extest install path"
for d in scx-bin extest-bin; do
    head=$(grep -E '^FROM ' "${src}/${d}/Containerfile" | head -n1)
    [[ "${head}" =~ ^FROM\ registry.fedoraproject.org/fedora:45@sha256:[0-9a-f]{64}\ AS\ build$ ]] && ok "${d}: the builder is Fedora 45 pinned by digest" || bad "${d}: builder FROM: ${head}"
    [[ "$(grep -E '^FROM ' "${src}/${d}/Containerfile" | tail -n1)" == "FROM scratch" ]] && ok "${d}: the published stage is FROM scratch" || bad "${d}: final stage"
    grep -q '/binary-build/fetch-source.sh /upstream.env /src' "${src}/${d}/Containerfile" && ok "${d}: the source comes through the commit-verifying fetch" || bad "${d}: fetch-source"
    sed -n '2,3p' "${src}/cosign.pub" | while read -r l; do grep -qF "${l}" "${src}/${d}/README.md" || exit 1; done && grep -q 'cosign verify --key' "${src}/${d}/README.md" && ok "${d}/README.md: pin by digest and the current cosign.pub" || bad "${d}/README.md"
done

# --- planning on a copy of the real repository
repo="${tmp}/repo"
mkdir -p "${repo}"
(cd "${src}" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "${repo}"
g() { git -C "${repo}" "$@"; }
g init -q -b main
g add -A
g commit -q -m base
last=$(g rev-parse HEAD)
names() { # <expected, sorted> <description> <path to touch>
    local want=$1 d=$2 f=$3 new out got
    echo "# $RANDOM" >> "${repo}/${f}"
    g add -A
    g commit -q -m "touch ${f}"
    new=$(g rev-parse HEAD)
    out=$(REPO_ROOT="${repo}" "${repo}/.github/scripts/plan-images.sh" push "${last}" "${new}" 2>/dev/null)
    got=$(python3 -I -c 'import json,sys; print(" ".join(sorted(e["image"] for e in json.loads(sys.argv[1])["include"])) or "-")' "${out}")
    last=${new}
    [[ "${got}" == "${want}" ]] && ok "${d}" || bad "${d} (want '${want}', got '${got}')"
}
names "scx-bin" "a change to scx-bin/upstream.env builds scx-bin only" scx-bin/upstream.env
names "extest-bin" "a change to extest-bin/upstream.env builds extest-bin only" extest-bin/upstream.env
names "scx-bin" "a change to the scx-bin Containerfile builds scx-bin only" scx-bin/Containerfile
names "extest-bin scx-bin" "a change to the shared build scripts builds both binary images" binary-build/stage.sh
names "dna-packages dna-toolbox" "a change to a list image does not build the binary images" dna-packages/README.md
# the promote decision: binary-build is the image's own path, so a later change there blocks the promotion
for n in scx-bin extest-bin; do
    own=$(REPO_ROOT="${src}" bash -c 'source "$1"; image_extra_paths "$2"' _ "${images}" "${n}")
    [[ " ${own} " == *" binary-build "* ]] && ok "${n}: binary-build is its own path for the promote decision" || bad "${n} extra paths: ${own}"
done

# --- the parser
w() { printf '%s\n' "$2" > "${tmp}/$1"; }
good=$(printf 'UPSTREAM_REPO=a/b\nUPSTREAM_TAG=v1.2.3\nUPSTREAM_COMMIT=%s\n' "$(sha a)")
w good.env "${good}"
(upstream_env_load "${tmp}/good.env" 2> /dev/null && [[ "${UPSTREAM_TAG}" == v1.2.3 && "${UPSTREAM_REPO}" == a/b ]]) && ok "parser: a valid file" || bad "parser: valid"
w c.env "# comment
${good}  # trailing
"
(upstream_env_load "${tmp}/c.env" 2> /dev/null) && ok "parser: comments and blank lines" || bad "parser: comments"
w q.env "$(sed 's/=v1.2.3/="v1.2.3"/' <<<"${good}")"
(upstream_env_load "${tmp}/q.env" 2> /dev/null && [[ "${UPSTREAM_TAG}" == v1.2.3 ]]) && ok "parser: quotes are stripped" || bad "parser: quotes"
w e.env "$(printf 'UPSTREAM_REPO=a/b\nUPSTREAM_TAG=\nUPSTREAM_COMMIT=%s\n' "$(sha b)")"
(upstream_env_load "${tmp}/e.env" 2> /dev/null && [[ -z "${UPSTREAM_TAG}" ]]) && ok "parser: an empty tag is a commit pin" || bad "parser: empty tag"
for tc in "short commit:$(sed 's/UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=abc123/' <<<"${good}")" \
    "uppercase commit:$(sed 's/UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD/' <<<"${good}")" \
    "no commit:$(grep -v COMMIT <<<"${good}")" \
    "bad repo:$(sed 's#UPSTREAM_REPO=.*#UPSTREAM_REPO=nonsense#' <<<"${good}")" \
    "unknown key:${good}"$'\nFOO=bar' \
    "duplicate key:${good}"$'\nUPSTREAM_TAG=v2' \
    "shell syntax:${good}"$'\n$(touch /tmp/x)' \
    "bad tag:$(sed 's/=v1.2.3/=v1 2/' <<<"${good}")"; do
    w bad.env "${tc#*:}"
    (upstream_env_load "${tmp}/bad.env" > /dev/null 2>&1) && bad "parser accepts: ${tc%%:*}" || ok "parser rejects: ${tc%%:*}"
done
cp "${tmp}/good.env" "${tmp}/set.env"
upstream_env_set "${tmp}/set.env" v9.9.9 "$(sha c)" && grep -qx "UPSTREAM_TAG=v9.9.9" "${tmp}/set.env" && grep -qx "UPSTREAM_REPO=a/b" "${tmp}/set.env" && ok "upstream_env_set rewrites tag and commit only" || bad "upstream_env_set"
upstream_env_set "${tmp}/set.env" v9 short 2> /dev/null && bad "upstream_env_set accepts a short commit" || ok "upstream_env_set refuses a bad commit"

# --- the commit-SHA verification of the checkout
up="${tmp}/up/o/p.git"
mkdir -p "${up}"
git init -q -b main "${up}"
echo one > "${up}/f"; git -C "${up}" add f; git -C "${up}" commit -q -m one
c1=$(git -C "${up}" rev-parse HEAD)
git -C "${up}" tag -a v1 -m v1
echo two > "${up}/f"; git -C "${up}" commit -q -a -m two
c2=$(git -C "${up}" rev-parse HEAD)
git -C "${up}" tag light
fetch() { # tag commit -> rc
    printf 'UPSTREAM_REPO=o/p\nUPSTREAM_TAG=%s\nUPSTREAM_COMMIT=%s\n' "$1" "$2" > "${tmp}/f.env"
    rm -rf "${tmp}/co"
    UPSTREAM_BASE_URL="file://${tmp}/up" "${src}/binary-build/fetch-source.sh" "${tmp}/f.env" "${tmp}/co" > "${tmp}/fetch.log" 2>&1
}
fetch v1 "${c1}" && [[ "$(git -C "${tmp}/co" rev-parse HEAD)" == "${c1}" ]] && ok "fetch: an annotated tag resolving to the pinned commit is checked out (peeled)" || bad "fetch annotated: $(cat "${tmp}/fetch.log")"
fetch light "${c2}" && ok "fetch: a lightweight tag at the pinned commit" || bad "fetch lightweight"
fetch v1 "${c2}" && bad "fetch: a tag that does not match the pin must fail" || { grep -q 'moved tag' "${tmp}/fetch.log" && ok "fetch: a tag that resolves to another commit fails (moved tag)"; }
fetch "" "${c2}" && ok "fetch: a commit pin at a fetchable commit" || bad "fetch commit pin: $(cat "${tmp}/fetch.log")"
fetch v1 0000000000000000000000000000000000000000 && bad "fetch: a wrong commit must fail" || ok "fetch: a pin that is not the tag's commit fails"
fetch nosuchtag "${c1}" && bad "fetch: a missing tag must fail" || ok "fetch: a missing tag fails"

# --- stage.sh: layout, SOURCE, BUILDINFO, smoke test
sdir="${tmp}/srcdir"
mkdir -p "${sdir}/target/release" "${sdir}/lic"
cp "$(type -P true)" "${sdir}/target/release/tool"
echo "license text" > "${sdir}/lic/LICENSE"
stage() { rm -rf "${tmp}/out"; "${src}/binary-build/stage.sh" --out "${tmp}/out" --env "${tmp}/good.env" --src "${sdir}" "$@" > "${tmp}/stage.log" 2>&1; }
stage --bin target/release/tool:bin/tool --license lic/LICENSE:up-LICENSE --smoke bin/tool:--version && ok "stage: succeeds" || bad "stage: $(cat "${tmp}/stage.log")"
[[ -x "${tmp}/out/bin/tool" && -s "${tmp}/out/LICENSES/up-LICENSE" && -s "${tmp}/out/SOURCE" && -s "${tmp}/out/BUILDINFO" ]] && ok "stage: /bin, /LICENSES, /SOURCE and /BUILDINFO exist" || bad "stage layout"
grep -qx "commit=$(sha a)" "${tmp}/out/SOURCE" && grep -qx 'tag=v1.2.3' "${tmp}/out/SOURCE" && grep -q '^repository=https://github.com/a/b$' "${tmp}/out/SOURCE" && grep -q '^built=20' "${tmp}/out/SOURCE" && ok "stage: SOURCE has repository, tag, 40-hex commit and build date" || bad "SOURCE: $(cat "${tmp}/out/SOURCE")"
grep -q '^rustc:' "${tmp}/out/BUILDINFO" && grep -q '^cargo:' "${tmp}/out/BUILDINFO" && grep -q '^clang:' "${tmp}/out/BUILDINFO" && grep -q '^needs bin/tool:' "${tmp}/out/BUILDINFO" && ok "stage: BUILDINFO has rustc, cargo, clang and the needed libraries" || bad "BUILDINFO"
stage --bin target/release/missing:bin/x --license lic/LICENSE:l && bad "stage: a missing build output must fail" || ok "stage: a missing build output fails"
stage --bin target/release/tool:bin/tool --license lic/missing:l && bad "stage: a missing license must fail" || ok "stage: a missing license file fails"
printf '#!/bin/sh\nexit 3\n' > "${sdir}/target/release/broken"
stage --bin target/release/broken:bin/broken --license lic/LICENSE:l --smoke bin/broken:--version && bad "stage: a failing smoke test must fail" || ok "stage: a binary that fails --version fails the build"
stage --bin target/release/tool:bin/tool --license lic/LICENSE:l --elf-x86-64 bin/tool && ok "stage: an x86-64 ELF object passes the architecture check" || bad "elf check: $(cat "${tmp}/stage.log")"
printf 'not elf' > "${sdir}/target/release/text"
stage --bin target/release/text:bin/text --license lic/LICENSE:l --elf-x86-64 bin/text 2> /dev/null && bad "stage: a non-ELF file must fail the check" || ok "stage: a file that is not an ELF object fails the check"

# --- the weekly upstream check with a stub gh (replies from files named after the API path)
mkdir -p "${tmp}/bin" "${tmp}/gh"
cat > "${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_LOG}"
[[ "$1" == api ]] || exit 99
path=${2//\//_}
if [[ -f "${GH_DIR}/${path}" ]]; then cat "${GH_DIR}/${path}"; [[ ! -f "${GH_DIR}/${path}.fail" ]]; else exit 1; fi
STUB
chmod +x "${tmp}/bin/gh"
export GH_LOG="${tmp}/gh.log" GH_DIR="${tmp}/gh"
crepo="${tmp}/crepo"
mkdir -p "${crepo}/binary-build" "${crepo}/.github/scripts" "${crepo}/img"
cp "${src}/binary-build/upstream-env.sh" "${crepo}/binary-build/"
cp "${src}/.github/scripts/upstream-check.sh" "${crepo}/.github/scripts/"
chk() { REPO_ROOT="${crepo}" PATH="${tmp}/bin:${PATH}" "${crepo}/.github/scripts/upstream-check.sh" img; }
reply() { rm -f "${GH_DIR}"/*; : > "${GH_LOG}"; while [[ $# -gt 0 ]]; do printf '%s\n' "$2" > "${GH_DIR}/$1"; shift 2; done; }
printf 'UPSTREAM_REPO=o/p\nUPSTREAM_TAG=v1.1.4\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${crepo}/img/upstream.env"
reply repos_o_p_releases_latest v1.1.4
[[ "$(chk)" == current* ]] && ok "check: the pinned tag is the latest release: current" || bad "check equal: $(chk)"
reply repos_o_p_releases_latest v1.1.5 repos_o_p_commits_v1.1.5 "$(sha b)"
[[ "$(chk)" == "bump v1.1.5 $(sha b)" ]] && ok "check: a newer release: bump with the tag and its commit" || bad "check newer: $(chk)"
reply repos_o_p_releases_latest v1.10.0 repos_o_p_commits_v1.10.0 "$(sha c)"
[[ "$(chk)" == "bump v1.10.0 $(sha c)" ]] && ok "check: versions compare numerically (v1.10.0 is newer than v1.1.4)" || bad "check version sort: $(chk)"
reply repos_o_p_releases_latest v1.0.9
[[ "$(chk)" == current* ]] && ok "check: a pin ahead of the latest release is current" || bad "check ahead: $(chk)"
reply
[[ "$(chk)" == unreachable* ]] && ok "check: upstream unreachable fails soft with a notice" || bad "check unreachable: $(chk)"
reply repos_o_p_releases_latest v1.1.5
[[ "$(chk)" == unreachable* ]] && ok "check: a tag that cannot be resolved to a commit fails soft" || bad "check unresolvable: $(chk)"
# commit pin
printf 'UPSTREAM_REPO=o/p\nUPSTREAM_TAG=\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${crepo}/img/upstream.env"
reply repos_o_p_releases_latest 1.0.3 repos_o_p_commits_1.0.3 "$(sha d)" "repos_o_p_compare_$(sha a)...$(sha d)" behind
[[ "$(chk)" == report* ]] && ok "check: a commit pin with only an older release reports and opens nothing" || bad "check commit pin behind: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" diverged
[[ "$(chk)" == "bump 1.1.0 $(sha e)" ]] && ok "check: a tag that is not an ancestor of the pinned commit (diverged): bump" || bad "check commit pin diverged: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" ahead
[[ "$(chk)" == "bump 1.1.0 $(sha e)" ]] && ok "check: a commit pin with a release ahead of it: bump" || bad "check commit pin ahead: $(chk)"
reply repos_o_p_tags "1.2.0" repos_o_p_commits_1.2.0 "$(sha f)" "repos_o_p_compare_$(sha a)...$(sha f)" ahead
[[ "$(chk)" == "bump 1.2.0 $(sha f)" ]] && ok "check: no release object, newest tag ahead of the commit: bump" || bad "check tag only: $(chk)"
reply repos_o_p_tags ""
[[ "$(chk)" == report* ]] && ok "check: no release and no tag: report only" || bad "check no tags: $(chk)"
reply repos_o_p_releases_latest 1.0.3 repos_o_p_commits_1.0.3 "$(sha a)" "repos_o_p_compare_$(sha a)...$(sha a)" identical
[[ "$(chk)" == current* ]] && ok "check: the pinned commit is the latest release: current" || bad "check identical: $(chk)"
! grep -qE 'gh (pr|repo|release) |--method|-X ' "${GH_LOG}" && ok "check: only reads (gh api GET)" || bad "check wrote something"

# --- bump-pr.sh: new PR, already open, older PR updated; a local origin, a stub gh, no force-push
origin="${tmp}/origin.git"
git init -q --bare -b testing "${origin}"
wc="${tmp}/wc"
mkdir -p "${wc}/binary-build" "${wc}/.github/scripts" "${wc}/img"
cp "${src}/binary-build/upstream-env.sh" "${wc}/binary-build/"
cp "${src}/.github/scripts/bump-pr.sh" "${src}/.github/scripts/images.sh" "${wc}/.github/scripts/"
printf 'IMAGE_NAME=img-bin\nIMAGE_KIND=binary\n' > "${wc}/img/image.env"
echo 'FROM scratch' > "${wc}/img/Containerfile"
printf '# pin\nUPSTREAM_REPO=o/p\nUPSTREAM_TAG=v1.1.4\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${wc}/img/upstream.env"
git -C "${wc}" init -q -b testing
git -C "${wc}" add -A && git -C "${wc}" commit -q -m base
git -C "${wc}" remote add origin "${origin}"
git -C "${wc}" push -q origin testing
cat > "${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_LOG}"
case "$1 $2" in
    "pr list") cat "${PR_LIST:-/dev/null}" ;;
    "pr create"|"pr edit") exit 0 ;;
    *) exit 99 ;;
esac
STUB
bump() { PR_LIST="${tmp}/prlist" PATH="${tmp}/bin:${PATH}" REPO_ROOT="${wc}" BUMP_TOKEN_SET="${TOKEN:-false}" "${wc}/.github/scripts/bump-pr.sh" img "$@" > "${tmp}/bump.log" 2>&1; }
: > "${tmp}/prlist"; : > "${GH_LOG}"
bump v1.1.5 "$(sha b)" && ok "bump: a new PR is opened" || bad "bump new: $(cat "${tmp}/bump.log")"
grep -q '^gh pr create --base testing --head bump/img-bin --title Bump img-bin to v1.1.5' "${GH_LOG}" && ok "bump: PR from bump/<image> into testing, titled with the version" || bad "bump create call: $(cat "${GH_LOG}")"
body=$(cat "${GH_LOG}")
[[ "${body}" == *"releases/tag/v1.1.5"* && "${body}" == *"compare/v1.1.4...v1.1.5"* ]] && ok "bump: body links the release notes and the compare URL" || bad "bump body"
[[ "${body}" == *"closing and reopening"* ]] && ok "bump: without BUMP_TOKEN the body says how to start the checks" || bad "bump body note"
: > "${GH_LOG}"; : > "${tmp}/prlist"; TOKEN=true bump v1.1.5 "$(sha b)" 2> /dev/null
[[ "$(git -C "${origin}" show bump/img-bin:img/upstream.env | grep -c "$(sha b)")" == 1 ]] && ok "bump: the branch carries the new pin" || bad "bump branch content"
[[ "$(git -C "${origin}" diff --name-only testing bump/img-bin)" == "img/upstream.env" ]] && ok "bump: only upstream.env changes" || bad "bump diff: $(git -C "${origin}" diff --name-only testing bump/img-bin)"
printf '{"number":7,"title":"Bump img-bin to v1.1.5"}\n' > "${tmp}/prlist"; : > "${GH_LOG}"
bump v1.1.5 "$(sha b)" && ! grep -qE '^gh pr (create|edit)' "${GH_LOG}" && ok "bump: a PR for that version is already open: nothing happens" || bad "bump already open"
printf '{"number":7,"title":"Bump img-bin to v1.1.5"}\n' > "${tmp}/prlist"; : > "${GH_LOG}"
bump v1.1.6 "$(sha c)" && grep -q '^gh pr edit 7 --title Bump img-bin to v1.1.6' "${GH_LOG}" && ok "bump: a PR for an older version is updated, not duplicated" || bad "bump update: $(cat "${tmp}/bump.log")"
[[ "$(git -C "${origin}" log --format=%s testing..bump/img-bin | wc -l)" -ge 2 && "$(git -C "${origin}" show bump/img-bin:img/upstream.env | grep -c "$(sha c)")" == 1 ]] && ok "bump: the update is a new commit on the same branch (no force-push)" || bad "bump update commit"
! git -C "${origin}" log --format=%B bump/img-bin | grep -qi 'co-authored-by' && ok "bump: no commit trailers" || bad "bump trailer"

# --- the workflows
python3 -I - "${src}" <<'PY'
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1]); wf = root / ".github/workflows"
fail = 0
def r(ok, msg):
    global fail
    print(("ok   " if ok else "FAIL ") + msg); fail += (not ok)
up = yaml.safe_load((wf / "upstream-check.yml").read_text()); on = up.get("on", up.get(True))
r(on["schedule"] == [{"cron": "0 7 * * 1"}] and "workflow_dispatch" in on and "push" not in on and "pull_request" not in on, "upstream-check.yml: Monday 07:00 UTC plus manual dispatch only")
text = (wf / "upstream-check.yml").read_text()
r("packages: write" not in text and "podman" not in text and "cosign" not in text and "ghcr.io" not in text, "upstream-check.yml: publishes nothing")
r(up["permissions"] == {"contents": "write", "pull-requests": "write"}, "upstream-check.yml: contents and pull-requests write only")
r("secrets.BUMP_TOKEN || secrets.GITHUB_TOKEN" in text and "BUMP_TOKEN_SET" in text, "upstream-check.yml: BUMP_TOKEN when set, else the default token")
r("echo ${{ secrets" not in text and "echo \"${GH_TOKEN}\"" not in text, "upstream-check.yml: no token is printed")
r(up["jobs"]["check"]["name"] == "Check upstream releases", "upstream-check.yml: its job name is not a required check name")
b = (wf / "build-image.yml").read_text()
r("images.sh version-tag" in b and "Check binary image contents" in b and "env.KIND == 'binary'" in b, "build-image.yml: version tag and the binary contents check")
bw = yaml.safe_load((wf / "build.yml").read_text()); bon = bw.get("on", bw.get(True))
r(bw["jobs"]["result"]["name"] == "Build and push image" and bw["jobs"]["signed"]["name"] == "Sign and verify images" and set(bon) == {"schedule", "push", "workflow_dispatch"}, "build.yml: triggers and the two check names are unchanged")
sys.exit(1 if fail else 0)
PY
rc=$?
[[ ${rc} -eq 0 ]] || failn=$((failn + 1))

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
