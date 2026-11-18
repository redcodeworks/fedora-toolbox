#!/usr/bin/env bash
# Slim checks of the datastore box files: no network, no podman. Run: tests/datastore-box.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
d="${src}/datastore"
pass=0
failn=0
ok() {
	pass=$((pass + 1))
	echo "ok   $1"
}
bad() {
	failn=$((failn + 1))
	echo "FAIL $1"
}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

# the image is discovered and scheduled like the other boxes
REPO_ROOT="${src}" "${src}/.github/scripts/images.sh" list | cut -f1,2 | grep -qx $'datastore\tdatastore' && ok "datastore is an image" || bad "datastore is not discovered"
[[ -d "${src}/datastore-images" ]] && ok "datastore-images is untouched (still there)" || bad "datastore-images is gone"

# downloads.lock: name|version|url|algorithm|checksum, pinned, https, checksum of the right length
n=0
while IFS='|' read -r name version url algo sum; do
	case "${name}" in '' | '#'*) continue ;; esac
	n=$((n + 1))
	[[ "${url}" == https://* && "${url}" == *"${version}"* ]] || bad "${name}: url is not https or does not carry the version"
	case "${algo}" in sha256) len=64 ;; sha512) len=128 ;; *) len=0 ;; esac
	[[ "${#sum}" -eq "${len}" && "${sum}" =~ ^[0-9a-f]+$ ]] || bad "${name}: checksum is not a lowercase ${algo}"
done <"${d}/downloads.lock"
[[ "${n}" -eq 2 ]] && ok "downloads.lock pins seaweedfs and kafka with checksums" || bad "downloads.lock has ${n} entries, expected 2"
grep -q 'sum" -c' "${d}/build_files/build.sh" && ok "build.sh verifies the checksums" || bad "build.sh does not verify checksums"

# packages: official Fedora packages only, one token per line
bad_pkgs=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${d}/packages/required-fedora.txt" | grep -vE '^[A-Za-z0-9._+-]+$' || true)
[[ -z "${bad_pkgs}" ]] && ok "required-fedora.txt is one package per line" || bad "required-fedora.txt: ${bad_pkgs}"
grep -qx postgresql17-server "${d}/packages/required-fedora.txt" && ok "PostgreSQL 17 is the pinned major" || bad "postgresql17-server is not in required-fedora.txt"

# units: run as the box user (rendered at setup), no hard-coded user or home
for u in postgres valkey seaweedfs kafka; do
	f="${d}/units/datastore-${u}.service.in"
	[[ -f "${f}" ]] && grep -q '^User=@USER@$' "${f}" && ! grep -qE '/home/|User=(root|postgres|kevin)' "${f}" && ok "unit ${u} runs as @USER@" || bad "unit ${u} is missing or hard-codes a user"
done
grep -q '^RuntimeDirectory=postgresql$' "${d}/units/datastore-postgres.service.in" && ok "postgres recreates /run/postgresql on start" || bad "postgres unit lacks RuntimeDirectory=postgresql"
grep -q '^SuccessExitStatus=143$' "${d}/units/datastore-kafka.service.in" && ok "kafka treats exit 143 as a clean stop" || bad "kafka unit lacks SuccessExitStatus=143"

# the command renders every unit without a leftover placeholder, for the current user and for another one
"${d}/bin/datastore" render "${tmp}/units" >/dev/null 2>&1 && ! grep -rq '@[A-Z]*@' "${tmp}/units" && [[ "$(ls "${tmp}/units" | wc -l)" -eq 4 ]] && ok "render writes four units, no placeholder left" || bad "render failed or left a placeholder"
"${d}/bin/datastore" --help | grep -q 'datastore secrets list|show NAME|export' && ok "--help names the secrets contract" || bad "--help is incomplete"
"${d}/bin/datastore" nosuchcommand >/dev/null 2>&1 && bad "unknown command accepted" || ok "unknown command refused"

# the documented distrobox file: the aliases and ports the other services use
ini="${d}/distrobox.ini"
for a in pgsql postgresql valkey seaweedfs kafka; do grep -q -- "--network-alias ${a} " "${ini}" || grep -q -- "--network-alias ${a}\"\| -p" <<<"$(grep additional_flags "${ini}")" || bad "distrobox.ini lacks alias ${a}"; done
for p in 127.0.0.1:5432:5432 127.0.0.1:6379:6379 127.0.0.1:8333:8333 127.0.0.1:9333:9333 127.0.0.1:8889:8888 127.0.0.1:9092:9092; do grep -q -- "-p ${p}" "${ini}" || bad "distrobox.ini does not publish ${p}"; done
grep -q '^init=true$' "${ini}" && grep -q -- '--network lakehouse' "${ini}" && ok "distrobox.ini: init, lakehouse network, aliases and loopback ports" || bad "distrobox.ini lacks init or the lakehouse network"

echo "${pass} passed, ${failn} failed"
[[ "${failn}" -eq 0 ]]
