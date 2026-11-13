#!/usr/bin/env bash
# Assemble the content of a binary image in <out> (the final scratch stage copies it to /): the binaries, the upstream
# licenses, SOURCE and BUILDINFO, and smoke-test every binary that was staged.
#
#   stage.sh --out DIR --env upstream.env --src SRCDIR
#            --bin <path in SRCDIR>:<path in the image>     (repeat; installed mode 0755)
#            --license <path in SRCDIR>:<name in /LICENSES>  (repeat)
#            --smoke <path in the image>:<arguments>         (repeat; run, must exit 0)
#            --elf-x86-64 <path in the image>                (repeat; must be an x86-64 ELF object, for libraries)
#
# SOURCE: repository URL, tag, 40-hex commit, build date. BUILDINFO: rustc, cargo, clang, glibc and the shared
# libraries each staged file needs (so a consumer can check its image has them). A BPF scheduler cannot be loaded on
# a CI runner, so the smoke test only proves that the binary starts and parses its arguments.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=upstream-env.sh
source "${here}/upstream-env.sh"

out="" envfile="" src=""
bins=() licenses=() smokes=() elfs=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out=$2; shift 2 ;;
        --env) envfile=$2; shift 2 ;;
        --src) src=$2; shift 2 ;;
        --bin) bins+=("$2"); shift 2 ;;
        --license) licenses+=("$2"); shift 2 ;;
        --smoke) smokes+=("$2"); shift 2 ;;
        --elf-x86-64) elfs+=("$2"); shift 2 ;;
        *) echo "stage.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ -n "${out}" && -n "${envfile}" && -n "${src}" ]] || { echo "stage.sh: --out, --env and --src are required" >&2; exit 2; }
[[ ${#bins[@]} -gt 0 && ${#licenses[@]} -gt 0 ]] || { echo "stage.sh: at least one --bin and one --license are required" >&2; exit 2; }
upstream_env_load "${envfile}"

staged=()
for pair in "${bins[@]}"; do
    from="${src}/${pair%%:*}" to="${pair#*:}"
    [[ -f "${from}" ]] || { echo "stage.sh: build output missing: ${from}" >&2; exit 1; }
    install -D -m 0755 "${from}" "${out}/${to}"
    staged+=("${to}")
done
for pair in "${licenses[@]}"; do
    from="${src}/${pair%%:*}" to="${pair#*:}"
    [[ -s "${from}" ]] || { echo "stage.sh: license file missing or empty: ${from}" >&2; exit 1; }
    install -D -m 0644 "${from}" "${out}/LICENSES/${to}"
done

for pair in "${smokes[@]}"; do
    to="${pair%%:*}" args="${pair#*:}"
    echo "smoke: ${to} ${args}"
    # shellcheck disable=SC2086
    "${out}/${to}" ${args} > /dev/null
done
for to in "${elfs[@]}"; do
    readelf -h "${out}/${to}" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' || { echo "stage.sh: ${to} is not an x86-64 ELF object" >&2; exit 1; }
    echo "elf: ${to} is x86-64"
done

built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    echo "repository=https://github.com/${UPSTREAM_REPO}"
    echo "tag=${UPSTREAM_TAG}"
    echo "commit=${UPSTREAM_COMMIT}"
    echo "built=${built}"
} > "${out}/SOURCE"

tool() { if command -v "$1" > /dev/null; then "$@" 2>&1 | head -n1; else echo "not installed"; fi; }
{
    echo "rustc: $(tool rustc --version)"
    echo "cargo: $(tool cargo --version)"
    echo "clang: $(tool clang --version)"
    echo "glibc: $(tool ldd --version)"
    if command -v rpm > /dev/null; then echo "glibc package: $(rpm -q glibc 2>&1 | head -n1)"; fi
    for to in "${staged[@]}"; do
        echo "needs ${to}:"
        needed=$(ldd "${out}/${to}" 2>&1 || true)
        if grep -q 'not found' <<<"${needed}"; then echo "stage.sh: ${to} has unresolved libraries: ${needed}" >&2; exit 1; fi
        awk '/=>/ {print "  " $1} /^[[:space:]]*\// {print "  " $1}' <<<"${needed}" | sort -u
    done
} > "${out}/BUILDINFO"
echo "staged: ${staged[*]}"
