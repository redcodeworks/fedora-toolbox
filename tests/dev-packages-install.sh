#!/usr/bin/env bash
# Tests for dev-packages/install.sh with a stub dnf5 (no real dnf, no root, no network): plain names,
# @groups, alternatives (first exists, only the second exists, none exists), EXCLUDE, comment and
# blank handling, an unavailable package aborting, the cleanup and the shared list in the repo.
# Run: tests/dev-packages-install.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
installer="${src}/package-installer/install.sh"
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

# Stub dnf5. STUB_AVAILABLE: one package name per line (what the repos have); STUB_GROUPS likewise;
# STUB_LOG records every call. `repoquery` prints the queried name when it is available; `install`
# fails when a package or group is unavailable (like strict=1); `clean` is recorded.
cat > "${tmp}/bin/dnf5" <<'STUB'
#!/usr/bin/env bash
echo "dnf5 $*" >> "${STUB_LOG}"
args=("$@")
case " ${args[*]} " in
    *" repoquery "*)
        name="${args[-1]}"
        grep -Fxq -- "${name}" "${STUB_AVAILABLE}" && echo "${name}"
        exit 0
        ;;
    *" install "*)
        for a in "${args[@]}"; do
            case "${a}" in
                -*) ;;
                install) ;;
                @*) grep -Fxq -- "${a#@}" "${STUB_GROUPS}" || { echo "No match for group ${a}" >&2; exit 1; } ;;
                *) grep -Fxq -- "${a}" "${STUB_AVAILABLE}" || { echo "No match for argument: ${a}" >&2; exit 1; } ;;
            esac
        done
        exit 0
        ;;
    *" clean "*) exit 0 ;;
esac
echo "stub dnf5: unexpected call $*" >&2
exit 2
STUB
chmod +x "${tmp}/bin/dnf5"

export STUB_LOG="${tmp}/log" STUB_AVAILABLE="${tmp}/available" STUB_GROUPS="${tmp}/groups"
export PATH="${tmp}/bin:${PATH}"
export CLEANUP_ROOT="${tmp}/root"   # never touch the real /var or /root

printf '%s\n' gcc make libgit2_1.9-devel libfoo-devel libbar-new > "${STUB_AVAILABLE}"
printf '%s\n' c-development development-tools > "${STUB_GROUPS}"

# run <list-content> [VAR=value ...]: runs the installer on a list; sets rc, out and the install line
run() {
    local content=$1
    shift
    : > "${STUB_LOG}"
    printf '%s\n' "${content}" > "${tmp}/list.txt"
    out=$(env "$@" bash "${installer}" "${tmp}/list.txt" 2>&1)
    rc=$?
    install_line=$(grep ' install ' "${STUB_LOG}" || true)
}
expect_rc() { if [[ "${rc}" -eq "$1" ]]; then ok "$2"; else bad "$2 (rc ${rc}, want $1): ${out}"; fi; }
expect_install() { if [[ "${install_line}" == "dnf5 -y install --setopt=strict=1 $1" ]]; then ok "$2"; else bad "$2 (got '${install_line}')"; fi; }

run $'# header comment\n\n@c-development\n@development-tools   # trailing comment\n\ngcc\n  make  \n# gone\n'
expect_rc 0 "plain names, groups, comments and blank lines: success"
expect_install "@c-development @development-tools gcc make" "only real entries are installed, in order, strict=1, no skip-unavailable"
if grep -q 'repoquery' "${STUB_LOG}"; then bad "plain names must not be looked up"; else ok "plain names and groups are not looked up (dnf install decides)"; fi
if grep -q -- '--skip-unavailable' "${STUB_LOG}"; then bad "--skip-unavailable used"; else ok "no --skip-unavailable"; fi

run $'gcc\nlibgit2_1.9-devel|libgit2-devel'
expect_rc 0 "alternatives: first exists"
expect_install "gcc libgit2_1.9-devel" "first alternative wins"

run $'libnope-devel|libfoo-devel'
expect_rc 0 "alternatives: only the second exists"
expect_install "libfoo-devel" "second alternative is picked"
if grep -q 'resolved: libnope-devel|libfoo-devel -> libfoo-devel' <<<"${out}"; then ok "the resolution is printed"; else bad "resolution not printed: ${out}"; fi

run $'gcc\nlibnope-devel|libalsonope-devel'
expect_rc 1 "alternatives: none exists aborts"
if [[ -z "${install_line}" ]]; then ok "nothing is installed when an alternative fails to resolve"; else bad "installed despite a failed resolution"; fi
if grep -q 'none of the alternatives' <<<"${out}"; then ok "the failure says why"; else bad "no explanation: ${out}"; fi

run $'gcc\nlibnotthere-devel'
expect_rc 1 "an unavailable package aborts non-zero"
run $'@no-such-group\ngcc'
expect_rc 1 "an unavailable group aborts non-zero"
run $'libgit2_1.9-devel|@c-development'
expect_rc 1 "a group inside alternatives is rejected"
run $'# only comments\n\n'
expect_rc 1 "an empty list is an error"
run $'gcc make'
expect_rc 1 "two tokens on one line are rejected"

# EXCLUDE
run $'gcc\nmake\nlibfoo-devel' EXCLUDE="make libbar-new"
expect_rc 0 "EXCLUDE: success"
expect_install "gcc libfoo-devel" "EXCLUDE drops the named package"
if grep -q 'excluded: make' <<<"${out}"; then ok "EXCLUDE prints what it dropped"; else bad "exclusion not printed: ${out}"; fi
run $'gcc\n@c-development\nlibgit2_1.9-devel|libgit2-devel' EXCLUDE="@c-development libgit2-devel"
expect_install "gcc" "EXCLUDE drops a group and an entry through any of its alternatives"
run $'gcc\nlibnope-devel|libalsonope-devel' EXCLUDE="libalsonope-devel"
expect_rc 0 "an excluded entry need not exist on this release"
run $'gcc' EXCLUDE="gcc"
expect_rc 1 "excluding everything leaves nothing to install: error"

# cleanup
mkdir -p "${CLEANUP_ROOT}/var/cache/libdnf5" "${CLEANUP_ROOT}/var/log" "${CLEANUP_ROOT}/root/.ssh" "${CLEANUP_ROOT}/root/.cache" "${CLEANUP_ROOT}/keep"
touch "${CLEANUP_ROOT}/var/log/dnf5.log" "${CLEANUP_ROOT}/var/log/dnf5.log.1" "${CLEANUP_ROOT}/root/.viminfo" "${CLEANUP_ROOT}/keep/file"
run $'gcc'
if grep -q 'dnf5 clean all' "${STUB_LOG}"; then ok "dnf5 clean all runs"; else bad "dnf5 clean all not run"; fi
left=$(find "${CLEANUP_ROOT}" -mindepth 1 -not -path "${CLEANUP_ROOT}/keep*" -not -path "${CLEANUP_ROOT}/var" -not -path "${CLEANUP_ROOT}/var/log" -not -path "${CLEANUP_ROOT}/var/cache" -not -path "${CLEANUP_ROOT}/root" | head -n3)
if [[ -z "${left}" && -f "${CLEANUP_ROOT}/keep/file" ]]; then ok "build residue (dnf logs, caches, root's ssh, vim and cache) is removed, other files stay"; else bad "cleanup wrong: ${left}"; fi
touch "${CLEANUP_ROOT}/var/log/dnf5.log"
run $'gcc' NO_CLEANUP=1
if [[ -e "${CLEANUP_ROOT}/var/log/dnf5.log" ]] && ! grep -q 'clean all' "${STUB_LOG}"; then ok "NO_CLEANUP=1 skips the cleanup"; else bad "NO_CLEANUP not honored"; fi

# default list: dev.txt next to the script (copy both into a bind-mount-like directory)
mkdir -p "${tmp}/mnt"
cp "${src}/package-installer/install.sh" "${tmp}/mnt/"
printf 'gcc\n' > "${tmp}/mnt/dev.txt"
: > "${STUB_LOG}"
if out=$(bash "${tmp}/mnt/install.sh" 2>&1) && grep -q 'install --setopt=strict=1 gcc$' "${STUB_LOG}"; then ok "default list is dev.txt next to the script (works from a bind mount)"; else bad "default list not used: ${out}"; fi
if bash "${tmp}/mnt/install.sh" "${tmp}/missing.txt" >/dev/null 2>&1; then bad "a missing list should fail"; else ok "a missing list fails"; fi

# the real list: every alternative entry names a package or alternatives, libgit2 uses the newest name first
real="${src}/dev-packages/dev.txt"
if grep -qx 'libgit2_1.9-devel|libgit2-devel' "${real}"; then ok "real list: libgit2 has the alternatives, newest name first"; else bad "real list: libgit2 line missing"; fi
if [[ -e "${src}/fedora-toolbox/packages/dev.txt" ]]; then bad "the old fedora-toolbox/packages/dev.txt still exists"; else ok "old packages path is gone"; fi
entries=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${real}")
if [[ $(wc -l <<<"${entries}") -ge 100 ]] && ! grep -qE '[[:space:]]' <<<"${entries}"; then ok "real list: one token per line, $(wc -l <<<"${entries}") entries"; else bad "real list looks wrong"; fi
if ! grep -qE 'Fedora 44 (names|name)' "${real}"; then ok "real list: no stale 'Fedora 44 names' comment"; else bad "stale Fedora 44 comment"; fi

# real list through the stub: every entry resolves when the stub has everything except libgit2-devel
sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${real}" | tr '|' '\n' | grep -v '^@' | grep -vx 'libgit2-devel' > "${STUB_AVAILABLE}"
sed -n 's/^@//p' "${real}" > "${STUB_GROUPS}"
: > "${STUB_LOG}"
if out=$(bash "${installer}" "${real}" 2>&1) && grep -q 'libgit2_1.9-devel' "${STUB_LOG}"; then ok "real list: installs on a Fedora-45-like repo (libgit2_1.9-devel)"; else bad "real list failed on a 45-like stub: ${out}"; fi
grep -vx 'libgit2_1.9-devel' "${STUB_AVAILABLE}" > "${tmp}/a2"; echo libgit2-devel >> "${tmp}/a2"; mv "${tmp}/a2" "${STUB_AVAILABLE}"
: > "${STUB_LOG}"
if out=$(bash "${installer}" "${real}" 2>&1) && grep -q 'libgit2-devel' "${STUB_LOG}" && ! grep -q 'install .*libgit2_1.9-devel' "${STUB_LOG}"; then ok "real list: installs on a Fedora-44-like repo (libgit2-devel)"; else bad "real list failed on a 44-like stub: ${out}"; fi

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
