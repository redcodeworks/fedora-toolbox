#!/usr/bin/env bash
# Static checks of how dev-packages is built and published (no network, no podman): the plan builds it
# only when its directory changes (or on manual runs), build-image.yml publishes and signs it like
# every image, permissions are least privilege, every action is pinned by SHA, both the `testing` and
# the `latest` tags are signed and verified, and dev-toolbox uses the shared installer.
# Needs: bash, python3 with PyYAML. Run: tests/dev-packages-workflow.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
check() { # description command...
    local d=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "${d}"; else bad "${d}"; fi
}

if ! python3 -I -c 'import yaml' 2>/dev/null; then
    echo "SKIP the workflow checks: python3 has no PyYAML"
    out=""
    skipped=1
fi
[[ -n "${skipped:-}" ]] || out=$(python3 -I - "${src}" <<'PY'
import sys, re, yaml, pathlib
root = pathlib.Path(sys.argv[1])
res = []
def r(ok, msg): res.append(("ok   " if ok else "FAIL ") + msg)

build = yaml.safe_load((root/".github/workflows/build.yml").read_text())
image = yaml.safe_load((root/".github/workflows/build-image.yml").read_text())
on = build.get("on", build.get(True))
imon = image.get("on", image.get(True))

# triggers: push (testing, main), one schedule, manual run, no pull_request (tests/workflow-triggers.sh); no workflow-level paths filter
r(set(on["push"]["branches"]) == {"main", "testing"}, "push to main and testing publishes")
r("paths" not in on["push"] and "pull_request" not in on, "no workflow-level paths filter (it would leave required checks pending)")
r("workflow_dispatch" in on and len(on["schedule"]) == 1, "manual run and exactly one schedule")
r("workflow_call" in imon, "build-image.yml is the reusable workflow")

# the images job calls the reusable workflow with least privilege
images = build["jobs"]["images"]
r(images["uses"] == "./.github/workflows/build-image.yml", "images job uses build-image.yml")
r(images["permissions"] == {"contents": "read", "packages": "write"}, "images job: contents read, packages write only")

# job permissions in the reusable workflow
perm = {k: v.get("permissions") for k, v in image["jobs"].items()}
r(perm["build_push"] == {"contents": "read", "packages": "write"}, "build job: contents read, packages write only")
r(perm["sign"] == {"contents": "read", "packages": "write"}, "sign job: contents read, packages write only")
r(perm["promote"] == {"contents": "read", "packages": "write"}, "promote job: contents read, packages write only")
r(image["jobs"]["sign"].get("environment") == "signing", "only the sign job uses the signing environment")
r(all("environment" not in v for k, v in image["jobs"].items() if k != "sign"), "no other job reaches the signing key")

# every action pinned by a 40-hex SHA with a version comment (local actions excepted)
bad = []
for f in list((root/".github/workflows").glob("*.yml")) + [root/".github/actions/setup-tool/action.yml"]:
    for n, line in enumerate(f.read_text().splitlines(), 1):
        m = re.match(r"\s*(?:-\s*)?uses:\s*(\S+)(.*)", line)
        if not m or m.group(1).startswith("./"):
            continue
        if not re.search(r"@[0-9a-f]{40}$", m.group(1)) or not re.search(r"#\s*v?\d", m.group(2)):
            if "ublue-os/remove-unwanted-software" in m.group(1):
                continue  # existing pin by SHA without a version comment (template action)
            bad.append(f"{f.name}:{n}")
r(not bad, "every action is pinned by SHA with a version comment" + (f" (not: {bad})" if bad else ""))

text = (root/".github/workflows/build-image.yml").read_text()
# tags
r('alias="${tag} testing-${GITHUB_SHA::7} ${dated}"' in text, "testing push publishes testing, testing-<sha> and testing-<date>-<sha>")
r('dated="${tag}-$(date -u +%Y%m%d)-${GITHUB_SHA::7}"' in text and 'refs/heads/main) publish=true; tag=latest' in text, "main publishes latest and latest-<date>-<sha>")
# signing and verification of every digest and every tag
sign = image["jobs"]["sign"]["steps"]
names = " | ".join(s.get("name", "") for s in sign)
r("Sign every pushed digest" in names and "Verify every pushed digest and tag against cosign.pub" in names, "sign job signs every digest and verifies digests and tags")
verify = [s for s in sign if s.get("name", "").startswith("Verify")][0]["run"]
r("cosign verify --key cosign.pub \"${IMAGE}:${tag}\"" in verify and "for tag in ${ALIAS_TAGS}" in verify, "every tag is verified with cosign.pub")
# the build context comes from images.sh and a data image gets a contents check instead of a smoke test
r('images.sh context "${DIR}"' in text, "the build context comes from image.env (BUILD_CONTEXT)")
r("Check data image contents" in text and "hashFiles" in text, "a data image has a contents check instead of a smoke test")

# image.env of dev-packages
env = dict(l.split("=", 1) for l in (root/"dev-packages/image.env").read_text().splitlines() if "=" in l and not l.startswith("#"))
r(env.get("IMAGE_NAME") == "dev-packages" and env.get("IMAGE_KIND") == "list", "dev-packages: image name and kind")
r(env.get("IMAGE_SCHEDULE") == "false", "dev-packages: not rebuilt by the weekly schedule")
r("BUILD_CONTEXT" not in env, "dev-packages builds from its own directory")

# Containerfile labels
cf = (root/"dev-packages/Containerfile").read_text()
r(re.search(r"^FROM scratch$", cf, re.M) is not None, "dev-packages is FROM scratch")
for label in ["title", "description", "source", "revision", "version", "created", "licenses"]:
    r(f"org.opencontainers.image.{label}=" in cf, f"label org.opencontainers.image.{label}")
r('licenses="Apache-2.0"' in cf, "licenses label is explicit Apache-2.0")
r("Developer package list and installer shared by dev-toolbox and octarine-os-dx" in cf, "description label as agreed")
r("COPY dev.txt install.sh /" in cf and "COPY README.md /README" in cf, "the image carries /dev.txt, /install.sh and /README")

print("\n".join(res))
PY
)
echo "${out}"
pass=$((pass + $(grep -c '^ok' <<<"${out}")))
failn=$((failn + $(grep -c '^FAIL' <<<"${out}")))
[[ -n "${out}" || -n "${skipped:-}" ]] || bad "the python checks produced no output"

# dev-toolbox uses the shared installer from the build context
bs="${src}/fedora-toolbox/build_files/build.sh"
cf="${src}/fedora-toolbox/Containerfile"
check "dev-toolbox build.sh calls the shared installer on the shared list" grep -q '/ctx/dev-packages/install.sh /ctx/dev-packages/dev.txt' "${bs}"
check "dev-toolbox build.sh has no install loop of its own" bash -c "! grep -q 'mapfile' '${bs}' && ! grep -q 'dnf5 -y' '${bs}'"
check "dev-toolbox Containerfile copies dev-packages into its context stage" grep -q '^COPY dev-packages/dev.txt dev-packages/install.sh /dev-packages/' "${cf}"
check "dev-toolbox does not pull the published list image" bash -c "! grep -q 'ghcr.io/redcodeworks/dev-packages' '${cf}'"
check "dev-toolbox builds with the repository root as context" grep -qx 'BUILD_CONTEXT=.' "${src}/fedora-toolbox/image.env"
check "a change in dev-packages rebuilds dev-toolbox" grep -qx 'EXTRA_PATHS=dev-packages' "${src}/fedora-toolbox/image.env"
check "the old packages path is gone from dev-toolbox, the Justfile and the README" bash -c "! grep -rn 'fedora-toolbox/packages/dev.txt\|/ctx/packages' '${src}/fedora-toolbox' '${src}/Justfile' '${src}/README.md'"
check "dev-packages/README.md has the consumer contract" bash -c "grep -q 'AS devpkgs' '${src}/dev-packages/README.md' && grep -q 'cosign verify --key' '${src}/dev-packages/README.md' && grep -q 'EXCLUDE' '${src}/dev-packages/README.md' && grep -q 'dnf5' '${src}/dev-packages/README.md'"
check "dev-packages/README.md carries the current cosign.pub text" bash -c "sed -n '2,3p' '${src}/cosign.pub' | while read -r l; do grep -qF \"\$l\" '${src}/dev-packages/README.md' || exit 1; done"

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
