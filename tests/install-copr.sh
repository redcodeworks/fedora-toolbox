#!/usr/bin/env bash
# Tests for package-installer/install-copr.sh with a stub dnf5 (no real dnf, no root, no network): the order
# enable, install, disable per entry, the disable after a failed install, rejection of entries without an
# exact version and release, a missing copr plugin, and the shape of the shipped copr.txt.
# Run: tests/install-copr.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
installer="${src}/package-installer/install-copr.sh"
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
# STUB_LOG records the calls; STUB_NO_COPR=1: `dnf5 copr` does not exist; STUB_FAIL: an install argument that fails
cat > "${tmp}/bin/dnf5" <<'STUB'
#!/usr/bin/env bash
echo "dnf5 $*" >> "${STUB_LOG}"
case "$1" in
    copr)
        [[ -z "${STUB_NO_COPR:-}" ]] || { echo "Unknown argument copr" >&2; exit 2; }
        exit 0 ;;
    install)
        for a in "$@"; do [[ "${a}" == "${STUB_FAIL:-@none@}" ]] && { echo "No match for argument: ${a}" >&2; exit 1; }; done
        exit 0 ;;
    *) ;;
esac
case " $* " in
    *" copr "*) exit 0 ;;
    *" install "*) for a in "$@"; do [[ "${a}" == "${STUB_FAIL:-@none@}" ]] && { echo "No match for argument: ${a}" >&2; exit 1; }; done; exit 0 ;;
    *" clean "*) exit 0 ;;
esac
exit 2
STUB
chmod +x "${tmp}/bin/dnf5"
export STUB_LOG="${tmp}/log" PATH="${tmp}/bin:${PATH}" CLEANUP_ROOT="${tmp}/root"

run() { : > "${STUB_LOG}"; NO_CLEANUP=1 bash "${installer}" "$@" 2>&1; }

printf '# comment\nowner/one:Pkg-One-1.2.3-4.fc45\n\nowner/two:other-pkg-2026.914.233613-1.fc45\n' > "${tmp}/two.txt"
out=$(run "${tmp}/two.txt"); rc=$?
want=$'dnf5 copr --help\ndnf5 -y copr enable owner/one\ndnf5 -y install --setopt=strict=1 Pkg-One-1.2.3-4.fc45\ndnf5 -y copr disable owner/one\ndnf5 -y copr enable owner/two\ndnf5 -y install --setopt=strict=1 other-pkg-2026.914.233613-1.fc45\ndnf5 -y copr disable owner/two'
[[ ${rc} -eq 0 && "$(cat "${STUB_LOG}")" == "${want}" ]] && ok "per entry: enable, one strict install of the exact NVR, disable (names with dashes and case kept)" || bad "order (rc ${rc}): $(cat "${STUB_LOG}")"

out=$(STUB_FAIL=Pkg-One-1.2.3-4.fc45 run "${tmp}/two.txt"); rc=$?
[[ ${rc} -ne 0 && "${out}" == *"could not install Pkg-One-1.2.3-4.fc45 from the COPR owner/one"* ]] && ok "a failed install fails with a message naming the package and the COPR" || bad "failed install (rc ${rc}): ${out}"
grep -qx 'dnf5 -y copr disable owner/one' "${STUB_LOG}" && ok "the COPR is disabled again after a failed install" || bad "no disable after failure: $(cat "${STUB_LOG}")"
grep -q 'owner/two' "${STUB_LOG}" && bad "later entries must not run after a failure" || ok "nothing runs after the failure"

for badentry in 'owner/one:Pkg' 'owner/one:Pkg-1.2.3' 'owner/one:Pkg-latest-1' 'Pkg-1.2.3-4' 'owner:Pkg-1-1' 'owner/one:Pkg-1.2.3-4 extra'; do
    printf '%s\n' "${badentry}" > "${tmp}/bad.txt"
    out=$(run "${tmp}/bad.txt"); rc=$?
    [[ ${rc} -ne 0 && "${out}" == *"exact version and release is required"* ]] && ok "rejected: ${badentry}" || bad "not rejected (rc ${rc}): ${badentry}: ${out}"
    grep -q 'copr enable' "${STUB_LOG}" && bad "nothing may be enabled for a rejected list: ${badentry}"
done

out=$(STUB_NO_COPR=1 run "${tmp}/two.txt"); rc=$?
[[ ${rc} -ne 0 && "${out}" == *"dnf5-plugins"* ]] && ok "a missing copr plugin is a clear error" || bad "missing plugin (rc ${rc}): ${out}"
grep -q 'enable' "${STUB_LOG}" && bad "nothing may be enabled without the plugin" || ok "nothing is enabled without the plugin"

: > "${tmp}/empty.txt"
run "${tmp}/empty.txt" >/dev/null && bad "an empty list must fail" || ok "an empty list fails"
run "${tmp}/missing.txt" >/dev/null && bad "a missing list must fail" || ok "a missing list fails"
bash "${installer}" >/dev/null 2>&1 && bad "no list argument must fail" || ok "no list argument fails"

# the cleanup runs unless NO_CLEANUP=1
: > "${STUB_LOG}"
bash "${installer}" "${tmp}/two.txt" >/dev/null 2>&1 && grep -qx 'dnf5 clean all' "${STUB_LOG}" && ok "the cleanup runs by default" || bad "cleanup"

# the shipped list
if [[ -f "${src}/gaming-packages/copr.txt" ]]; then
    cp "${src}/gaming-packages/copr.txt" "${tmp}/shipped.txt"
    out=$(run "${tmp}/shipped.txt"); rc=$?
    [[ ${rc} -eq 0 ]] && grep -q 'dnf5 -y install --setopt=strict=1 Sunshine-' "${STUB_LOG}" && ok "gaming-packages/copr.txt passes the installer's checks (Sunshine, exact NVR)" || bad "shipped copr.txt (rc ${rc}): ${out}"
else
    bad "gaming-packages/copr.txt missing"
fi

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
