#!/usr/bin/env bash
# Tests for the package-manifest images (dev-packages, dna-packages, gaming-packages) and the toolbox images that build from
# the same files: the images are in the matrix and out of the weekly schedule, a change to one list builds only the images
# that use it, the installer handles the two dna tiers and the gaming entries, and the toolbox builds install exactly the
# package set the old build scripts installed (reference: the old sed-based algorithm, kept inline below).
# No network, no podman, stub dnf5. Needs: bash, git, python3. Run: tests/package-manifests.sh
# shellcheck disable=SC2015,SC2016
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
images="${src}/.github/scripts/images.sh"

# --- discovery: names, kinds, schedule, data files
list=$(REPO_ROOT="${src}" "${images}" list | cut -f1,2 | tr '\t\n' ' ')
for pair in "dna-packages dna-packages" "gaming-packages gaming-packages" "dev-packages dev-packages" "dna-toolbox dna-toolbox" "fedora-gaming fedora-gaming"; do
    [[ "${list}" == *"${pair} "* ]] && ok "image listed: ${pair%% *}" || bad "image list lacks ${pair%% *}: ${list}"
done
sched=$(REPO_ROOT="${src}" "${src}/.github/scripts/plan-images.sh" schedule)
for n in dev-packages dna-packages gaming-packages; do
    [[ "${sched}" != *"\"${n}\""* ]] && ok "the weekly schedule leaves ${n} out" || bad "the weekly schedule rebuilds ${n}"
done
for n in dna-toolbox fedora-gaming fedora-toolbox; do
    [[ "${sched}" == *"\"${n}\""* ]] && ok "the weekly schedule still builds ${n}" || bad "the weekly schedule lacks ${n}"
done
for d in dev-packages dna-packages gaming-packages; do
    while IFS=: read -r s dst; do
        [[ -f "${src}/${s}" && -n "${dst}" ]] || bad "${d}: DATA_FILES entry ${s}:${dst} is not a file"
    done < <(REPO_ROOT="${src}" "${images}" data-files "${d}")
    [[ "$(REPO_ROOT="${src}" "${images}" data-files "${d}" | wc -l)" -ge 3 ]] && ok "${d}: DATA_FILES names the lists, the installer and the README" || bad "${d}: DATA_FILES too short"
done

# --- planning on a copy of the real repository
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
    echo "# $RANDOM" >> "${repo}/${f}"
    g add -A
    g commit -q -m "touch ${f}"
    new=$(g rev-parse HEAD)
    out=$(REPO_ROOT="${repo}" "${repo}/.github/scripts/plan-images.sh" push "${last}" "${new}" 2>/dev/null)
    got=$(python3 -I -c 'import json,sys; print(" ".join(sorted(e["image"] for e in json.loads(sys.argv[1])["include"])) or "-")' "${out}")
    last=${new}
    [[ "${got}" == "${want}" ]] && ok "${d}" || bad "${d} (want '${want}', got '${got}')"
}
names "fedora-gaming gaming-packages" "a change to gaming.txt builds gaming-packages and fedora-gaming only" gaming-packages/gaming.txt
names "dna-packages dna-toolbox" "a change to core.txt builds dna-packages and dna-toolbox only" dna-packages/core.txt
names "dna-packages dna-toolbox" "a change to optional.txt builds dna-packages and dna-toolbox only" dna-packages/optional.txt
names "dev-packages fedora-toolbox" "a change to dev.txt builds dev-packages and fedora-toolbox only" dev-packages/dev.txt
names "dna-toolbox" "a change inside dna-toolbox builds only dna-toolbox" dna-toolbox/versions.env
names "fedora-gaming" "a change inside fedora-gaming builds only fedora-gaming" fedora-gaming/build_files/build.sh
names "dev-packages dna-packages dna-toolbox fedora-gaming fedora-toolbox gaming-packages" "a change to the shared installer builds every manifest image and toolbox" package-installer/install.sh

# the promote decision: a list change after the tested commit blocks promotion for the images that use it only (extra paths)
own=$(REPO_ROOT="${src}" bash -c 'source "$1"; image_extra_paths dna-toolbox' _ "${images}")
[[ " ${own} " == *" dna-packages "* && " ${own} " == *" package-installer "* ]] && ok "dna-toolbox: dna-packages and package-installer are its own paths for the promote decision" || bad "dna-toolbox extra paths: ${own}"
own=$(REPO_ROOT="${src}" bash -c 'source "$1"; image_extra_paths fedora-gaming' _ "${images}")
[[ " ${own} " == *" gaming-packages "* && " ${own} " == *" package-installer "* ]] && ok "fedora-gaming: gaming-packages and package-installer are its own paths for the promote decision" || bad "fedora-gaming extra paths: ${own}"

# --- the installer against fixtures (stub dnf5)
mkdir -p "${tmp}/bin" "${tmp}/mnt"
cat > "${tmp}/bin/dnf5" <<'STUB'
#!/usr/bin/env bash
echo "dnf5 $*" >> "${STUB_LOG}"
case " $* " in
    *" repoquery "*) exit 0 ;;
    *" install "*) for a in "$@"; do [[ "${a}" == "${STUB_FAIL:-@none@}" ]] && { echo "No match for argument: ${a}" >&2; exit 1; }; done; exit 0 ;;
    *" clean "*) exit 0 ;;
esac
exit 2
STUB
chmod +x "${tmp}/bin/dnf5"
export STUB_LOG="${tmp}/log" PATH="${tmp}/bin:${PATH}" CLEANUP_ROOT="${tmp}/root"
installer="${src}/package-installer/install.sh"

printf 'a\nb\n' > "${tmp}/core.txt"
printf 'x\ny\n' > "${tmp}/optional.txt"
: > "${STUB_LOG}"
NO_CLEANUP=1 bash "${installer}" "${tmp}/core.txt" > /dev/null 2>&1 && grep -qx 'dnf5 -y install --setopt=strict=1 a b' "${STUB_LOG}" && ok "core tier: one strict install" || bad "core tier"
: > "${STUB_LOG}"
NO_CLEANUP=1 OPTIONAL=1 bash "${installer}" "${tmp}/optional.txt" > /dev/null 2>&1 && [[ "$(cat "${STUB_LOG}")" == $'dnf5 -y install x\ndnf5 -y install y' ]] && ok "optional tier: one package at a time, no strict flag" || bad "optional tier: $(cat "${STUB_LOG}")"
: > "${STUB_LOG}"
out=$(STUB_FAIL=x NO_CLEANUP=1 OPTIONAL=1 bash "${installer}" "${tmp}/optional.txt" 2>&1); rc=$?
[[ ${rc} -eq 0 && "${out}" == *"WARNING optional package 'x' not installed"* ]] && grep -qx 'dnf5 -y install y' "${STUB_LOG}" && ok "optional tier: a failing package warns, the rest installs, exit 0" || bad "optional failure (rc ${rc}): ${out}"
STUB_FAIL=a NO_CLEANUP=1 bash "${installer}" "${tmp}/core.txt" > /dev/null 2>&1 && bad "core tier: an unavailable package must fail" || ok "core tier: an unavailable package fails"
: > "${tmp}/empty.txt"
NO_CLEANUP=1 OPTIONAL=1 bash "${installer}" "${tmp}/empty.txt" > /dev/null 2>&1 && ok "optional tier: nothing to install is fine" || bad "optional empty"
NO_CLEANUP=1 bash "${installer}" "${tmp}/empty.txt" > /dev/null 2>&1 && bad "core tier: an empty list must fail" || ok "core tier: an empty list fails"
# default list: the only .txt next to the script, or an error when there are several
cp "${installer}" "${tmp}/mnt/"
printf 'g\n' > "${tmp}/mnt/gaming.txt"
: > "${STUB_LOG}"
NO_CLEANUP=1 bash "${tmp}/mnt/install.sh" > /dev/null 2>&1 && grep -qx 'dnf5 -y install --setopt=strict=1 g' "${STUB_LOG}" && ok "one list next to the installer is the default" || bad "single default list"
cp "${tmp}/core.txt" "${tmp}/optional.txt" "${tmp}/mnt/" && rm "${tmp}/mnt/gaming.txt"
NO_CLEANUP=1 bash "${tmp}/mnt/install.sh" > /dev/null 2>&1 && bad "two lists and no argument must fail" || ok "two lists and no argument: the list must be named"

# --- the toolbox builds install exactly what the old build scripts did
ref_entries() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }   # the old algorithm
# dna-toolbox: the invocations in build.sh, run as written
bs="${src}/dna-toolbox/build_files/build.sh"
grep -q '^NO_CLEANUP=1 bash /ctx/dna-packages/install.sh /ctx/dna-packages/core.txt$' "${bs}" && grep -q '^NO_CLEANUP=1 OPTIONAL=1 bash /ctx/dna-packages/install.sh /ctx/dna-packages/optional.txt$' "${bs}" && ok "dna-toolbox build.sh installs core strictly and optional best effort through the installer" || bad "dna-toolbox build.sh invocations"
: > "${STUB_LOG}"
NO_CLEANUP=1 bash "${installer}" "${src}/dna-packages/core.txt" > /dev/null 2>&1
NO_CLEANUP=1 OPTIONAL=1 bash "${installer}" "${src}/dna-packages/optional.txt" > /dev/null 2>&1
want="dnf5 -y install --setopt=strict=1 $(ref_entries "${src}/dna-packages/core.txt" | tr '\n' ' ' | sed 's/ $//')"
while read -r p; do want+=$'\n'"dnf5 -y install ${p}"; done < <(ref_entries "${src}/dna-packages/optional.txt")
[[ "$(cat "${STUB_LOG}")" == "${want}" ]] && ok "dna-toolbox: the dnf calls equal the old build.sh's ($(ref_entries "${src}/dna-packages/core.txt" | wc -l) core in one strict install, $(ref_entries "${src}/dna-packages/optional.txt" | wc -l) optional one by one)" || bad "dna-toolbox package set differs"
# fedora-gaming
bs="${src}/fedora-gaming/build_files/build.sh"
grep -q '^NO_CLEANUP=1 bash /ctx/gaming-packages/install.sh "\$list"$' "${bs}" && grep -q '^list=/ctx/gaming-packages/gaming.txt$' "${bs}" && ok "fedora-gaming build.sh installs gaming.txt through the installer" || bad "fedora-gaming build.sh invocation"
: > "${STUB_LOG}"
NO_CLEANUP=1 bash "${installer}" "${src}/gaming-packages/gaming.txt" > /dev/null 2>&1
want="dnf5 -y install --setopt=strict=1 $(ref_entries "${src}/gaming-packages/gaming.txt" | tr '\n' ' ' | sed 's/ $//')"
[[ "$(cat "${STUB_LOG}")" == "${want}" ]] && ok "fedora-gaming: the dnf call equals the old build.sh's ($(ref_entries "${src}/gaming-packages/gaming.txt" | wc -l) entries, name.arch and groups unchanged)" || bad "fedora-gaming package set differs"
# the Containerfiles copy the shared files, not copies
for pair in "dna-toolbox:dna-packages/core.txt dna-packages/optional.txt package-installer/install.sh /dna-packages/" "fedora-gaming:gaming-packages/gaming.txt package-installer/install.sh /gaming-packages/"; do
    grep -qF "COPY ${pair#*:}" "${src}/${pair%%:*}/Containerfile" && ok "${pair%%:*}: the Containerfile copies the shared files" || bad "${pair%%:*}: Containerfile copy"
done
[[ ! -e "${src}/dna-toolbox/packages" && ! -e "${src}/fedora-gaming/packages" ]] && ok "no second copy of the lists inside the toolbox directories" || bad "a toolbox directory still has packages/"

# the manifest images carry the shared installer and the cosign key in their README
for d in dna-packages gaming-packages; do
    grep -q 'cosign verify --key' "${src}/${d}/README.md" && sed -n '2,3p' "${src}/cosign.pub" | while read -r l; do grep -qF "${l}" "${src}/${d}/README.md" || exit 1; done && ok "${d}/README.md: consumer contract and the current cosign.pub" || bad "${d}/README.md"
    grep -q 'COPY dna-packages\|COPY gaming-packages' "${src}/${d}/Containerfile" && grep -q 'COPY .*package-installer/install.sh /' "${src}/${d}/Containerfile" && ok "${d}: the image carries the shared installer" || bad "${d}: Containerfile"
done

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
