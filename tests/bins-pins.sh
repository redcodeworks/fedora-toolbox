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

# --- the real Containerfiles: pinned, shaped as lint expects, one digest per variant
for d in fedora-toolbox dna-toolbox; do
    grep -qE '^FROM ghcr\.io/redcodeworks/octarine-bins-dx@\$\{BINS_DIGEST\} AS bins$' "${src}/${d}/Containerfile" && ok "${d} pins octarine-bins-dx by digest" || bad "${d} does not pin octarine-bins-dx"
done
grep -qE '^FROM ghcr\.io/redcodeworks/octarine-bins-gx@\$\{BINS_DIGEST\} AS bins$' "${src}/fedora-gaming/Containerfile" && ok "fedora-gaming pins octarine-bins-gx by digest" || bad "fedora-gaming does not pin octarine-bins-gx"
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
# the registry stub: latest and the tags 20261117-1234567 and 20261116-9999999 are the stub manifest, newer dated tags are other manifests,
# inputs-* is not a dated tag; STUB_NOMATCH=1 leaves no dated tag on the pinned digest; STUB_LABEL=1 gives the image an (ignored) version label
cat > "${tmp}/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *list-tags*) echo '{"Tags":["latest","inputs-0123456789abcdef01234567","20261116-9999999","20261119-ccccccc","20261117-1234567","20261118-bbbbbbb"]}' ;;
    *--config*) [[ "${STUB_LABEL:-}" == 1 ]] && echo '{"config":{"Labels":{"org.opencontainers.image.version":"20250101-deadbee"}}}' || echo '{"config":{"Labels":{}}}' ;;
    *--raw*:latest | *--raw*:inputs-* | *--raw*:20261117-1234567 | *--raw*:20261116-9999999)
        [[ "${STUB_NOMATCH:-}" == 1 && "$*" != *:latest ]] && echo '{"manifest":"other"}' || echo '{"manifest":"stub"}' ;;
    *--raw*) echo '{"manifest":"other"}' ;;
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
export RETRY_TRIES=1 RETRY_DELAY=0
run() { PATH="${tmp}/bin:${PATH}" REPO_ROOT="${repo}" "${src}/.github/scripts/bins-pins.sh" "$@"; }

COSIGN_FAIL=1 run bump dx > /dev/null 2>&1 && bad "bump writes although cosign fails" || ok "a failed verification stops the bump"
grep -q "${old}" "${repo}/a/Containerfile" && ok "nothing was written after the failed verification" || bad "the Containerfile changed after a failed verification"
run bump dx > /dev/null 2>&1 && ok "bump dx succeeds" || bad "bump dx failed"
for x in a b; do grep -q "ARG BINS_DIGEST=sha256:${new}" "${repo}/${x}/Containerfile" && grep -q 'ARG BINS_TAG=20261117-1234567' "${repo}/${x}/Containerfile" && ok "${x}: digest and tag written" || bad "${x}: pin not written"; done
grep -q "${old}" "${repo}/c/Containerfile" && ok "the gx pin is untouched by a dx bump" || bad "a dx bump changed the gx Containerfile"
grep -q -- "--key ${repo}/keys/octarine-bins.pub .*octarine-bins-dx@sha256:${new}" "${COSIGN_LOG}" && ok "the digest was verified with keys/octarine-bins.pub" || bad "cosign was not called with the key and the digest"
run verify a > /dev/null 2>&1 && ok "verify passes for a pinned image" || bad "verify failed"
COSIGN_FAIL=1 run verify a > /dev/null 2>&1 && bad "verify passes although cosign fails" || ok "verify fails when the signature does not check out"
# a digest with no dated tag fails plainly and writes nothing
mkdir -p "${tmp}/snap" && cp "${repo}/a/Containerfile" "${tmp}/snap/a"
STUB_NOMATCH=1 run bump dx > "${tmp}/nomatch.out" 2>&1 && bad "bump succeeds although no dated tag points at the digest" || ok "no dated tag on the digest fails the bump"
grep -q "sha256:${new}" "${tmp}/nomatch.out" && ok "the failure names the digest" || bad "the failure does not name the digest"
cmp -s "${repo}/a/Containerfile" "${tmp}/snap/a" && ok "nothing written without a dated tag" || bad "a Containerfile changed without a dated tag"
# the tag comes from the registry whether or not the image still has a version label
for lab in 0 1; do
    sed -i "s/^ARG BINS_TAG=.*/ARG BINS_TAG=20260101-aaaaaaa/" "${repo}/a/Containerfile"
    STUB_LABEL=${lab} run bump dx > /dev/null 2>&1 && grep -q '^ARG BINS_TAG=20261117-1234567$' "${repo}/a/Containerfile" && ok "tag from the registry, newest of the tags on the digest (label=${lab})" || bad "wrong tag with label=${lab}"
done
run bump zz > /dev/null 2>&1 && bad "an unknown kind is accepted" || ok "an unknown kind is refused"

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
