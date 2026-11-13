#!/usr/bin/env bash
# Build every scheduler named in scx-bin/schedulers.txt from the checked-out scx source and stage the image content.
#
#   build.sh <schedulers.txt> <upstream.env> <source dir> <out dir>
#
# One cargo invocation for all of them: cargo build --release --locked -p <a> -p <b> ... Then stage.sh installs
# target/release/<name> as /bin/<name>, copies the LICENSE of the scheduler's directory (found under scheds/) next to the
# repository LICENSE, and runs <name> --version. Adding a scheduler is a line in schedulers.txt, not a code change.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
list="${1:?schedulers.txt}"
envfile="${2:?upstream.env}"
srcdir="${3:?source dir}"
out="${4:?out dir}"
stage="${STAGE_SH:-${here}/../binary-build/stage.sh}"

mapfile -t names < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "${list}")
[[ ${#names[@]} -gt 0 ]] || { echo "build.sh: no scheduler in ${list}" >&2; exit 1; }
dups=$(printf '%s\n' "${names[@]}" | sort | uniq -d)
[[ -z "${dups}" ]] || { echo "build.sh: duplicate scheduler: ${dups}" >&2; exit 1; }

pkgs=() args=()
for n in "${names[@]}"; do
    [[ "${n}" =~ ^[a-z0-9_]+$ ]] || { echo "build.sh: bad scheduler name '${n}'" >&2; exit 1; }
    pkgs+=(-p "${n}")
    args+=(--bin "target/release/${n}:bin/${n}" --smoke "bin/${n}:--version")
    sdir=$(find "${srcdir}/scheds" -mindepth 2 -maxdepth 2 -type d -name "${n}" | head -n1)
    [[ -n "${sdir}" ]] || { echo "build.sh: ${n} is not a scheduler directory under scheds/ of the source" >&2; exit 1; }
    args+=(--license "${sdir#"${srcdir}/"}/LICENSE:${n}-LICENSE")
done

(cd "${srcdir}" && cargo build --release --locked "${pkgs[@]}")
"${stage}" --out "${out}" --env "${envfile}" --src "${srcdir}" --license "LICENSE:scx-LICENSE" "${args[@]}" \
    --info "schedulers: ${names[*]}"
