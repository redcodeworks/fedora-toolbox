#!/usr/bin/env bash
# Tests .github/scripts/retry.sh (waits for a read of something just written) and that the workflow uses it for every
# read-after-write: the promote read-back, the verify before retagging and the sign job's verify. No network.
# Run: tests/retry.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
retry="$here/.github/scripts/retry.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad() {
    echo "FAIL $1"
    fail=1
}
export RETRY_DELAY=0 RETRY_TRIES=5

# a command that fails the first N times (counter in a file)
cat >"$tmp/flaky" <<'F'
#!/usr/bin/env bash
n=$(( $(cat "${COUNTER}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${COUNTER}"
[[ "${n}" -gt "${FAILS}" ]] && { echo "value"; exit 0; }
echo "not there yet" >&2; exit 2
F
chmod +x "$tmp/flaky"
export COUNTER="$tmp/count"

rm -f "$COUNTER"
export FAILS=0
out=$("$retry" "$tmp/flaky" 2>/dev/null)
rc=$?
[[ $rc -eq 0 && "$out" == value && "$(cat "$COUNTER")" == 1 ]] && pass "success on the first try: one call, output passed through" || bad "first try"
rm -f "$COUNTER"
export FAILS=3
out=$("$retry" "$tmp/flaky" 2>/dev/null)
rc=$?
[[ $rc -eq 0 && "$out" == value && "$(cat "$COUNTER")" == 4 ]] && pass "succeeds after three failures" || bad "after failures"
rm -f "$COUNTER"
export FAILS=99
"$retry" "$tmp/flaky" >/dev/null 2>"$tmp/err"
rc=$?
[[ $rc -eq 2 && "$(cat "$COUNTER")" == 5 ]] && grep -q 'still failing after 5 attempts' "$tmp/err" && pass "gives up after RETRY_TRIES with the command's own exit status" || bad "give up (rc $rc)"
"$retry" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "no command: usage error" || bad "no command"

echo "== workflow"
f="$here/.github/workflows/build-image.yml"
[[ "$(grep -c 'retry.sh cosign verify' "$f")" == 3 ]] && pass "the three cosign verifies of freshly written data go through retry.sh" || bad "cosign verify without retry"
grep -q 'retry.sh skopeo inspect --raw "docker://${image}:${tag}"' "$f" && pass "the promote read-back of a tag it just copied goes through retry.sh" || bad "promote read-back"
grep -q 'retry.sh' "$here/.github/scripts/push-tags.sh" && pass "push-tags.sh reads its tags back through retry.sh" || bad "push-tags read-back"
exit "${fail}"
