#!/usr/bin/env bash
# Test that `just new-image` scaffolds a toolbox image that passes the repo's lint and is picked up
# by the planning script, in a temporary copy of the repo (the real tree is not touched).
# No network. Needs: bash, tar, git. Run: tests/new-image.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
copy="${tmp}/copy"
mkdir -p "${copy}"
(cd "${src}" && tar --exclude=.git -cf - .) | tar -xf - -C "${copy}"

if REPO_ROOT="${copy}" "${copy}/.github/scripts/lint.sh" >/dev/null 2>&1; then ok "lint passes before scaffolding"; else bad "lint fails on the unmodified copy"; fi

if "${copy}/.github/scripts/new-image.sh" demo-box >/dev/null; then ok "new-image demo-box succeeds"; else bad "new-image failed"; fi
for f in Containerfile build_files/build.sh packages/dev.txt tests/smoke.sh; do
    if [[ -e "${copy}/demo-box/${f}" ]]; then ok "scaffold has ${f}"; else bad "scaffold lacks ${f}"; fi
done
if grep -q '^FROM ghcr.io/ublue-os/fedora-toolbox:latest' "${copy}/demo-box/Containerfile"; then ok "scaffold builds FROM a toolbox base"; else bad "scaffold FROM line wrong"; fi
if grep -rIiE 'bootc|ostree|kernel|iso|disk' "${copy}/demo-box" >/dev/null; then bad "scaffold mentions OS-image parts"; else ok "scaffold has no bootc/ostree/kernel/disk/ISO parts"; fi

if REPO_ROOT="${copy}" "${copy}/.github/scripts/lint.sh" >/dev/null 2>&1; then ok "scaffold passes lint"; else
    bad "scaffold fails lint:"; REPO_ROOT="${copy}" "${copy}/.github/scripts/lint.sh" 2>&1 | sed 's/^/     /'
fi
if "${copy}/.github/scripts/new-image.sh" demo-box >/dev/null 2>&1; then bad "scaffolding an existing name should fail"; else ok "refuses an existing name"; fi
if "${copy}/.github/scripts/new-image.sh" "Bad Name" >/dev/null 2>&1; then bad "bad name accepted"; else ok "refuses an invalid name"; fi
if [[ "$(REPO_ROOT="${copy}" "${copy}/.github/scripts/images.sh" list | cut -f2 | tr '\n' ' ')" == "demo-box fedora-toolbox " ]]; then ok "image name equals directory name"; else bad "image list wrong"; fi

# An OS-image part in a toolbox directory must fail lint
echo 'RUN bootc container lint' >> "${copy}/demo-box/Containerfile"
if REPO_ROOT="${copy}" "${copy}/.github/scripts/lint.sh" >/dev/null 2>&1; then bad "lint accepted a bootc line"; else ok "lint rejects OS-image parts"; fi

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
