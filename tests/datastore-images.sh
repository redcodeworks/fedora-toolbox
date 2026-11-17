#!/usr/bin/env bash
# Tests for the datastore-images list image: the validator accepts the real file and rejects each bad case,
# the image is in the matrix and out of the weekly schedule, a change to it builds it alone, and the shape
# of its files (Containerfile, DATA_FILES, README). No network, no podman. Run: tests/datastore-images.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
val="${src}/datastore-images/validate.sh"
good="${src}/datastore-images/images.txt"

"${val}" "${good}" >/dev/null 2>&1 && ok "the real images.txt is valid" || bad "the real images.txt is invalid"

# a bad file is the real one with one change (sed expression); the validator must fail and name the problem
d=$(printf 'a%.0s' {1..64})
reject() { # description sed-expression expected-message-fragment
    sed -e "$2" "${good}" >"${tmp}/f.txt"
    out=$("${val}" "${tmp}/f.txt" 2>&1) && { bad "$1 accepted"; return; }
    [[ "${out}" == *"$3"* ]] && ok "$1 rejected" || bad "$1 rejected with the wrong message: ${out}"
}
reject "missing digest" '/^kafka /s/@sha256:[0-9a-f]*$//' "not '<name>"
reject "short digest" '/^kafka /s/@sha256:.*$/@sha256:abcdef/' "not '<name>"
reject "long digest" "/^kafka /s/\$/0/" "not '<name>"
reject "uppercase digest" "/^kafka /s/@sha256:.*\$/@sha256:${d^^}/" "not '<name>"
reject "latest tag" '/^kafka /s/:4\.3\.2@/:latest@/' "'latest' is not allowed"
reject "floating major tag" '/^kafka /s/:4\.3\.2@/:4@/' "not an exact version"
reject "floating major tag with suffix" '/^valkey /s/:9\.1\.3-alpine@/:9-alpine@/' "not an exact version"
reject "named tag" '/^kafka /s/:4\.3\.2@/:stable@/' "not an exact version"
reject "duplicate name" '/^valkey /{p;}' "duplicate name 'valkey'"
reject "unknown name" '/^kafka /s/^kafka /rabbitmq /' "unknown name 'rabbitmq'"
reject "missing name" '/^kafka /d' "missing image 'kafka'"
reject "trailing garbage" '/^kafka /s/$/ # note/' "not '<name>"
reject "trailing space" '/^kafka /s/$/ /' "not '<name>"
reject "no tag" '/^kafka /s/:4\.3\.2@/@/' "not '<name>"
reject "upper case name" '/^kafka /s/^kafka /Kafka /' "not '<name>"
reject "leading space" '/^kafka /s/^/ /' "not '<name>"
: >"${tmp}/empty.txt"
"${val}" "${tmp}/empty.txt" >/dev/null 2>&1 && bad "an empty file accepted" || ok "an empty file rejected"
"${val}" "${tmp}/none.txt" >/dev/null 2>&1 && bad "a missing file accepted" || ok "a missing file rejected"
# comments and blank lines are fine anywhere
{ echo "# c"; echo; cat "${good}"; echo "   # indented comment"; } >"${tmp}/c.txt"
"${val}" "${tmp}/c.txt" >/dev/null 2>&1 && ok "comments and blank lines accepted" || bad "comments and blank lines rejected"
# every real line carries its major as a comment and a 64-hex digest
[[ "$(grep -cE '^(postgresql|valkey|seaweedfs|kafka) .*@sha256:[0-9a-f]{64}$' "${good}")" == 4 ]] && ok "four pinned lines" || bad "not four pinned lines"

# discovery: in the matrix, kind list, out of the weekly schedule, files exist
images="${src}/.github/scripts/images.sh"
[[ "$(REPO_ROOT="${src}" "${images}" list | cut -f2 | grep -cx datastore-images)" == 1 ]] && ok "datastore-images is in the image list" || bad "not in the image list"
sched=$(REPO_ROOT="${src}" "${src}/.github/scripts/plan-images.sh" schedule)
[[ "${sched}" != *'"datastore-images"'* ]] && ok "the weekly schedule leaves it out" || bad "the weekly schedule rebuilds it"
while IFS=: read -r s dst; do
    [[ -f "${src}/${s}" && -n "${dst}" ]] || bad "DATA_FILES entry ${s}:${dst} is not a file"
done < <(REPO_ROOT="${src}" "${images}" data-files datastore-images)
# DATA_FILES covers images.txt, the README and every file of bin/, lib/ and quadlets/ (directory entries expand to their files)
want=$(cd "${src}/datastore-images" && ls images.txt bin/* lib/* quadlets/* | sed 's|.*|datastore-images/&:&|' | LC_ALL=C sort)
have=$(REPO_ROOT="${src}" "${images}" data-files datastore-images | grep -v 'README.md:README' | LC_ALL=C sort)
[[ "${want}" == "${have}" ]] && grep -qx 'datastore-images/README.md:README' <(REPO_ROOT="${src}" "${images}" data-files datastore-images) && ok "DATA_FILES: images.txt, README, bin, lib and quadlets, file for file" || bad "DATA_FILES wrong"

# planning on a copy of the repository: a change touching only datastore-images builds it and nothing else, and the reverse
repo="${tmp}/repo"
mkdir -p "${repo}"
(cd "${src}" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "${repo}"
g() { git -C "${repo}" -c user.name=t -c user.email=t@example.invalid "$@"; }
g init -q -b main
g add -A
g commit -q -m base
last=$(g rev-parse HEAD)
names() { # <expected, sorted> <description> <path to touch>
    local want=$1 d=$2 f=$3 new out got
    echo "# $RANDOM" >>"${repo}/${f}"
    g add -A
    g commit -q -m "touch ${f}"
    new=$(g rev-parse HEAD)
    out=$(REPO_ROOT="${repo}" "${repo}/.github/scripts/plan-images.sh" push "${last}" "${new}" 2>/dev/null)
    got=$(python3 -I -c 'import json,sys; print(" ".join(sorted(e["image"] for e in json.loads(sys.argv[1])["include"])) or "-")' "${out}")
    last=${new}
    [[ "${got}" == "${want}" ]] && ok "${d}" || bad "${d} (want '${want}', got '${got}')"
}
names "datastore-images" "a change to images.txt builds datastore-images only" datastore-images/images.txt
names "datastore-images" "a change to the validator builds datastore-images only" datastore-images/validate.sh
names "datastore-images" "a change to the datastore command builds datastore-images only" datastore-images/bin/datastore
names "datastore-images" "a change to a library builds datastore-images only" datastore-images/lib/datastore.sh
names "datastore-images" "a change to a Quadlet template builds datastore-images only" datastore-images/quadlets/valkey.container
names "dna-toolbox" "a change to a dna-toolbox list does not build datastore-images" dna-toolbox/packages/required-fedora.txt
names "fedora-toolbox" "a change to the fedora-toolbox pin builds only fedora-toolbox" fedora-toolbox/Containerfile

# the Containerfile and the README
cf="${src}/datastore-images/Containerfile"
grep -qE '^FROM scratch$' "${cf}" && grep -q '^COPY datastore-images/images.txt /$' "${cf}" && grep -q '^COPY datastore-images/README.md /README$' "${cf}" && ok "Containerfile: FROM scratch, carries images.txt and README" || bad "Containerfile shape"
grep -q 'org.opencontainers.image.title="datastore-images"' "${cf}" && grep -q 'image.revision="${IMAGE_REVISION}"' "${cf}" && grep -q 'image.created="${IMAGE_CREATED}"' "${cf}" && ok "Containerfile: OCI labels" || bad "Containerfile labels"
grep -q 'cosign verify --key' "${src}/datastore-images/README.md" && sed -n '2,3p' "${src}/cosign.pub" | while read -r l; do grep -qF "${l}" "${src}/datastore-images/README.md" || exit 1; done && ok "README: consumer contract and the current cosign.pub" || bad "README contract"
grep -q 'IMAGE_SCHEDULE=false' "${src}/datastore-images/image.env" && grep -q 'IMAGE_KIND=list' "${src}/datastore-images/image.env" && ok "image.env: list image, not scheduled" || bad "image.env"

echo
echo "${pass} passed, ${failn} failed"
((failn == 0))
