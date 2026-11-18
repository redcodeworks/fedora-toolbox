#!/usr/bin/env bash
# Tests for .github/scripts/bins-pins.sh and the pins in the real Containerfiles, with stub skopeo and cosign: no network, no podman.
# Run: tests/bins-pins.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

# --- the real Containerfiles that still pin: shaped as lint expects (fedora-gaming has its own lists and no pin since stage 2)
for d in fedora-toolbox dna-toolbox; do
    grep -qE '^FROM ghcr\.io/redcodeworks/octarine-bins-dx@\$\{BINS_DIGEST\} AS bins$' "${src}/${d}/Containerfile" && ok "${d} pins octarine-bins-dx by digest" || bad "${d} does not pin octarine-bins-dx"
done
[[ "$(grep -h '^ARG BINS_DIGEST=' "${src}/fedora-toolbox/Containerfile" "${src}/dna-toolbox/Containerfile" | sort -u | wc -l)" == 1 ]] && ok "the two dx pins are the same digest" || bad "fedora-toolbox and dna-toolbox pin different dx digests"
grep -q 'BEGIN PUBLIC KEY' "${src}/keys/octarine-bins.pub" && ok "keys/octarine-bins.pub is a public key" || bad "keys/octarine-bins.pub missing"
! grep -q 'PRIVATE' "${src}/keys/octarine-bins.pub" && ok "keys/octarine-bins.pub holds no private key" || bad "private key material in keys/"

# --- a scratch repo with stubs
repo="${tmp}/repo"
mkdir -p "${repo}/a" "${repo}/b" "${repo}/c" "${repo}/keys" "${tmp}/bin"
echo "-----BEGIN PUBLIC KEY-----" > "${repo}/keys/octarine-bins.pub"
old=$(printf 'a%.0s' {1..64})
for x in a b; do printf 'ARG BINS_TAG=20260101-aaaaaaa\nARG BINS_DIGEST=sha256:%s\nFROM ghcr.io/redcodeworks/octarine-bins-dx@${BINS_DIGEST} AS bins\n' "${old}" > "${repo}/${x}/Containerfile"; done
printf 'ARG BINS_TAG=20260101-aaaaaaa\nARG BINS_DIGEST=sha256:%s\nFROM ghcr.io/redcodeworks/octarine-bins-gx@${BINS_DIGEST} AS bins\n' "${old}" > "${repo}/c/Containerfile"
cat > "${tmp}/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *--raw*) echo '{"manifest":"stub"}' ;;
    *--config*) echo '{"config":{"Labels":{"org.opencontainers.image.version":"20261117-1234567"}}}' ;;
esac
STUB
cat > "${tmp}/bin/cosign" <<'STUB'
#!/usr/bin/env bash
[[ "${COSIGN_FAIL:-}" != 1 ]] || exit 1
echo "cosign $*" >> "${COSIGN_LOG}"
STUB
chmod +x "${tmp}/bin/skopeo" "${tmp}/bin/cosign"
new=$(printf '{"manifest":"stub"}\n' | sha256sum | sed 's/ .*//')
export COSIGN_LOG="${tmp}/cosign.log"
run() { PATH="${tmp}/bin:${PATH}" REPO_ROOT="${repo}" "${src}/.github/scripts/bins-pins.sh" "$@"; }

COSIGN_FAIL=1 run bump dx > /dev/null 2>&1 && bad "bump writes although cosign fails" || ok "a failed verification stops the bump"
grep -q "${old}" "${repo}/a/Containerfile" && ok "nothing was written after the failed verification" || bad "the Containerfile changed after a failed verification"
run bump dx > /dev/null 2>&1 && ok "bump dx succeeds" || bad "bump dx failed"
for x in a b; do grep -q "ARG BINS_DIGEST=sha256:${new}" "${repo}/${x}/Containerfile" && grep -q 'ARG BINS_TAG=20261117-1234567' "${repo}/${x}/Containerfile" && ok "${x}: digest and tag written" || bad "${x}: pin not written"; done
grep -q "${old}" "${repo}/c/Containerfile" && ok "the gx pin is untouched by a dx bump" || bad "a dx bump changed the gx Containerfile"
grep -q -- "--key ${repo}/keys/octarine-bins.pub .*octarine-bins-dx@sha256:${new}" "${COSIGN_LOG}" && ok "the digest was verified with keys/octarine-bins.pub" || bad "cosign was not called with the key and the digest"
run verify a > /dev/null 2>&1 && ok "verify passes for a pinned image" || bad "verify failed"
COSIGN_FAIL=1 run verify a > /dev/null 2>&1 && bad "verify passes although cosign fails" || ok "verify fails when the signature does not check out"
run bump zz > /dev/null 2>&1 && bad "an unknown kind is accepted" || ok "an unknown kind is refused"

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
