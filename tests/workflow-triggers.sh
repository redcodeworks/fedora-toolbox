#!/usr/bin/env bash
# Static checks of the GitLab Flow triggers and check names (no network): test.yml is the fast lane (dev-branch pushes and
# pull requests into testing, no image build), build.yml builds only on pushes to testing and main, the schedule and manual
# runs (never on pull_request), and the required check names stay as the rulesets expect them.
# Needs: bash, python3 with PyYAML. Run: tests/workflow-triggers.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! python3 -I -c 'import yaml' 2>/dev/null; then echo "SKIP: python3 has no PyYAML"; exit 0; fi
python3 -I - "$here" <<'PY'
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1]); wf = root / ".github/workflows"
fail = 0
def r(ok, msg):
    global fail
    print(("PASS " if ok else "FAIL ") + msg)
    fail += (not ok)
def load(n):
    d = yaml.safe_load((wf / n).read_text()); return d, d.get("on", d.get(True))

test, ton = load("test.yml")
r(ton["push"]["branches-ignore"] == ["main", "testing"], "test.yml: pushes to every branch except main and testing")
r(ton["pull_request"]["branches"] == ["testing"], "test.yml: pull requests into testing")
r(set(test["jobs"]) == {"test", "secrets"} and test["jobs"]["test"]["name"] == "test" and test["jobs"]["secrets"]["name"] == "secrets", "test.yml: jobs and check names are test and secrets")
text = (wf / "test.yml").read_text()
r("podman build" not in text and "push-tags" not in text and "packages: write" not in text and "ghcr.io" not in text, "test.yml: no image build and no publishing")
for cmd in ("just check", "just lint", "just test"):
    r(f"run: {cmd}" in text, f"test.yml runs {cmd}")

build, bon = load("build.yml")
r(set(bon) == {"schedule", "push", "workflow_dispatch"}, "build.yml: schedule, push and manual run only (no pull_request)")
r(bon["push"]["branches"] == ["main", "testing"], "build.yml: pushes to main and testing")
r(len(bon["schedule"]) == 1, "build.yml: exactly one schedule")
r("paths" not in bon["push"], "build.yml: no workflow-level paths filter")
r(build["jobs"]["result"]["name"] == "Build and push image", "build.yml: aggregate check is named Build and push image")
r(build["jobs"]["signed"]["name"] == "Sign and verify images", "build.yml: signing check is named Sign and verify images")
r("mirror" not in build["jobs"], "build.yml: no mirror job (a pull request has no build to wait for)")
for j in ("result", "signed"):
    r(build["jobs"][j]["if"] == "always()" and set(build["jobs"][j]["needs"]) == {"plan", "images"}, f"build.yml: {j} always reports on plan and images")
r("pull_request" not in (wf / "build.yml").read_text().replace("There is no pull_request trigger", ""), "build.yml: no pull_request reference left")
r("pull_request" not in (wf / "build-image.yml").read_text(), "build-image.yml: no pull_request reference")

rt, ron = load("require-testing-branch.yml")
r(ron["pull_request"]["branches"] == ["main"] and "require-testing-branch" in rt["jobs"] and rt["jobs"]["require-testing-branch"]["name"] == "require-testing-branch", "require-testing-branch.yml: pull requests into main, check name unchanged")
r("test" not in {j["name"] for n in ("build.yml", "require-testing-branch.yml") for j in yaml.safe_load((wf / n).read_text())["jobs"].values() if "name" in j}, "no other workflow has a job named test")
sys.exit(1 if fail else 0)
PY
