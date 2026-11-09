#!/usr/bin/env bash
# Test the prune safety rule that matters for promotion: a version that carries a `latest*` tag as
# well as `testing*` tags (a promoted image) is never deleted, nor is its cosign signature, while
# plain old testing builds and their signatures are. Dry run only, fake version list, no network.
# Needs: bash, python3. Run: tests/prune-testing.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
prune="${here}/../.github/scripts/prune-testing.py"
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

versions=$(python3 -I - <<'PY'
import json
def d(n): return "%064x" % n
vs = []
def image(i, day, tags):
    vs.append({"id": i, "name": "sha256:" + d(i), "created_at": f"2026-11-0{day}T00:00:00Z",
               "metadata": {"container": {"tags": tags}}})
def sig(i, day):
    vs.append({"id": 100 + i, "name": "sha256:" + d(100 + i), "created_at": f"2026-11-0{day}T00:00:01Z",
               "metadata": {"container": {"tags": [f"sha256-{d(i)}.sig"]}}})
# oldest build was promoted: testing tags plus latest tags on the same version
image(1, 1, ["testing-20261101-aaaaaa1", "testing-aaaaaa1", "latest", "latest-20261105-bbbbbb1"])
image(2, 2, ["testing-20261102-aaaaaa2", "testing-aaaaaa2"])
image(3, 3, ["testing-20261103-aaaaaa3", "testing-aaaaaa3"])
image(4, 4, ["testing-20261104-aaaaaa4", "testing-aaaaaa4"])
image(5, 5, ["testing-20261105-aaaaaa5", "testing-aaaaaa5", "testing"])
for i, day in [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]:
    sig(i, day)
print(json.dumps(vs))
PY
)

out=$(echo "${versions}" | DRY_RUN=true KEEP=2 python3 -I "${prune}" 2>&1)
# shellcheck disable=SC2001
echo "${out}" | sed 's/^/     /'
if grep -q "DELETE image id=2 " <<<"${out}"; then ok "old plain testing build is deleted"; else bad "old build 2 not in the plan"; fi
if grep -q "DELETE image id=3 " <<<"${out}"; then ok "second old testing build is deleted"; else bad "build 3 not in the plan"; fi
if grep -q "DELETE sig   id=102 " <<<"${out}"; then ok "its signature goes with it"; else bad "signature of build 2 not in the plan"; fi
if grep -q "DELETE image id=1 " <<<"${out}"; then bad "promoted version (testing and latest tags) would be deleted"; else ok "version with latest* and testing* tags is never deleted"; fi
if grep -q "DELETE sig   id=101 " <<<"${out}"; then bad "signature of the promoted version would be deleted"; else ok "signature of the promoted version is kept"; fi
if grep -qE "DELETE image id=(4|5) " <<<"${out}"; then bad "a newest testing build would be deleted"; else ok "the newest 2 testing builds are kept"; fi

# the 60-version limit still holds
many=$(python3 -I -c '
import json
vs=[{"id":i,"name":"sha256:%064x"%i,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["testing-20260101-%07x"%i]}}} for i in range(1,80)]
print(json.dumps(vs))')
if echo "${many}" | DRY_RUN=true KEEP=1 python3 -I "${prune}" >/dev/null 2>&1; then bad "deleting 78 versions was not refused"; else ok "refuses to delete more than the limit"; fi

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
