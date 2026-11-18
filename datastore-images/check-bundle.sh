#!/usr/bin/env bash
# Runs the datastore bundle from the files extracted out of the BUILT image (the build calls it before publishing):
#   check-bundle.sh <dir with bin/, lib/, quadlets/, images.txt as in the image>
# It proves that the image content works as the thin consumer uses it: --help, render, install into a temporary HOME
# (idempotent), uninstall, and that the rendered units equal the ones rendered from the repository files. Needs only
# bash and coreutils; systemctl is replaced by a stub. Run from the repository root. Not part of the image.
set -euo pipefail
dir=$(cd "${1:?usage: check-bundle.sh <extracted image dir>}" && pwd)
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
fail() {
    echo "check-bundle: $*" >&2
    exit 1
}

[[ -x "${dir}/bin/datastore" ]] || fail "bin/datastore is missing or not executable in the image"
[[ -x "${dir}/lib/render.sh" ]] || fail "lib/render.sh is missing or not executable in the image"
for f in images.txt lib/datastore.sh; do [[ -f "${dir}/${f}" ]] || fail "${f} is missing in the image"; done
ls "${dir}"/quadlets/* >/dev/null

mkdir -p "${tmp}/bin" "${tmp}/home"
printf '#!/bin/sh\necho "systemctl $*" >> "%s/systemctl.log"\n' "${tmp}" >"${tmp}/bin/systemctl"
chmod +x "${tmp}/bin/systemctl"
ds() { env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u DATASTORE_USER_DIR -u DATASTORE_STATE_DIR -u DATASTORE_IMAGES HOME="${tmp}/home" PATH="${tmp}/bin:${PATH}" "${dir}/bin/datastore" "$@"; }

ds --help >/dev/null || fail "datastore --help failed"
ds setup --help >/dev/null || fail "datastore setup --help failed"
"${repo}/datastore-images/lib/render.sh" "${tmp}/repo-render" "${repo}/datastore-images" >/dev/null
ds render "${tmp}/image-render" >/dev/null || fail "datastore render failed"
diff -r "${tmp}/repo-render" "${tmp}/image-render" || fail "the image renders other units than the repository files"
echo "ok: --help and render work, the rendered units equal the repository's"

units="${tmp}/home/.config/containers/systemd"
ds install >/dev/null || fail "datastore install failed"
diff -r "${tmp}/image-render" "${units}" || fail "install placed other files than render"
grep -qx 'systemctl --user daemon-reload' "${tmp}/systemctl.log" || fail "install did not reload systemd"
grep -q 'start' "${tmp}/systemctl.log" && fail "install started something"
before=$(stat -c '%i' "${units}"/*)
ds install >/dev/null || fail "the second install failed"
[[ "$(stat -c '%i' "${units}"/*)" == "${before}" ]] || fail "the second install rewrote files (not idempotent)"
echo "ok: install places the rendered units and is idempotent"
ds uninstall >/dev/null || fail "datastore uninstall failed"
[[ -z "$(ls -A "${units}")" ]] || fail "uninstall left files behind"
echo "ok: uninstall removes them again"
