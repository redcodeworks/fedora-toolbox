#!/usr/bin/env bash
# Renders the datastore Quadlets: copies quadlets/* to <outdir> and replaces every @<NAME>_IMAGE@ with the
# <image>:<tag>@<digest> of images.txt (parsed, never sourced). Fails on a bad line, a missing image or a
# placeholder that is left over.
#   render.sh <outdir> [<bundle dir> [<images.txt>]]
# <bundle dir> holds quadlets/ (default: the directory above this script), <images.txt> defaults to the one in it.
# images.txt: one line per image, `<name> <image>:<tag>@sha256:<digest>`, names postgresql valkey seaweedfs kafka,
# `#` comments and blank lines ignored. The tag is the exact version (never latest, never a floating major tag).
set -euo pipefail
out="${1:?usage: render.sh <outdir> [<bundle dir> [<images.txt>]]}"
src="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
list="${3:-${src}/images.txt}"
[[ -f "${list}" ]] || {
    echo "render: ${list} not found" >&2
    exit 1
}
[[ -d "${src}/quadlets" ]] || {
    echo "render: ${src}/quadlets not found" >&2
    exit 1
}
declare -A REF=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^(postgresql|valkey|seaweedfs|kafka)[[:space:]]+([^[:space:]]+)$ ]] || {
        echo "render: not '<name> <image>:<tag>@sha256:<digest>' (names postgresql valkey seaweedfs kafka): '${line}'" >&2
        exit 1
    }
    name=${BASH_REMATCH[1]} ref=${BASH_REMATCH[2]}
    [[ -z "${REF[${name}]:-}" ]] || {
        echo "render: ${name} is listed twice" >&2
        exit 1
    }
    [[ "${ref}" =~ ^([a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+):([^:@/]+)@(sha256:[0-9a-f]{64})$ ]] || {
        echo "render: bad image reference for ${name}: '${ref}' (needs <image>:<tag>@sha256:<64 hex>)" >&2
        exit 1
    }
    tag=${BASH_REMATCH[4]}
    [[ "${tag}" =~ ^[0-9]+(\.[0-9]+)+(-[a-z0-9.]+)?$ && "${tag}" != latest ]] || {
        echo "render: ${name} tag '${tag}' is not an exact version tag" >&2
        exit 1
    }
    REF["${name}"]=${ref}
done <"${list}"
for name in postgresql valkey seaweedfs kafka; do
    [[ -n "${REF[${name}]:-}" ]] || {
        echo "render: ${name} is missing from ${list}" >&2
        exit 1
    }
done
mkdir -p "${out}"
for f in "${src}"/quadlets/*; do cp "${f}" "${out}/$(basename "${f}")"; done
for name in postgresql valkey seaweedfs kafka; do
    sed -i "s|@${name^^}_IMAGE@|${REF[${name}]}|g" "${out}"/*.container
done
if grep -q '@[A-Z_]*@' "${out}"/*; then
    echo "render: a placeholder is left over" >&2
    exit 1
fi
rendered=("${out}"/*)
echo "rendered ${#rendered[@]} files into ${out}"
