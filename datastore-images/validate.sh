#!/usr/bin/env bash
# Validate datastore-images/images.txt (or the file given as the argument): every line is a comment, blank, or
#   <name> <image>:<tag>@sha256:<64 hex>
# with an exact (not latest, not major-only) tag, unique names, and exactly the expected set of names.
# Used by `just lint`, tests/datastore-images.sh and CI. Exit 1 with one message per problem.
set -uo pipefail

# The whitelist: extend it here when the datastore gains a service.
expected="kafka postgresql seaweedfs valkey"

file="${1:-$(dirname "${BASH_SOURCE[0]}")/images.txt}"
[[ -f "${file}" ]] || {
    echo "validate: ${file}: no such file" >&2
    exit 1
}

fail=0
err() {
    echo "validate: ${file}:$1: $2" >&2
    fail=1
}

line_re='^([a-z]+) ([a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9._-]+)+):([^@:[:space:]]+)@(sha256:[0-9a-f]{64})$'
tag_re='^[0-9]+\.[0-9]+(\.[0-9]+)*(-[A-Za-z0-9._]+)?$'

declare -A seen=()
n=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "${line}" =~ ${line_re} ]]; then
        err "${n}" "not '<name> <image>:<tag>@sha256:<64 hex>': ${line}"
        continue
    fi
    name="${BASH_REMATCH[1]}"
    tag="${BASH_REMATCH[5]}"
    if [[ "${tag}" == "latest" ]]; then
        err "${n}" "${name}: tag 'latest' is not allowed"
    elif [[ ! "${tag}" =~ ${tag_re} ]]; then
        err "${n}" "${name}: tag '${tag}' is not an exact version (needs major.minor at least, no floating major tag)"
    fi
    [[ " ${expected} " == *" ${name} "* ]] || err "${n}" "unknown name '${name}' (expected: ${expected})"
    [[ -z "${seen[${name}]:-}" ]] || err "${n}" "duplicate name '${name}' (first on line ${seen[${name}]})"
    seen[${name}]="${n}"
done <"${file}"

for name in ${expected}; do
    [[ -n "${seen[${name}]:-}" ]] || {
        echo "validate: ${file}: missing image '${name}'" >&2
        fail=1
    }
done

if ((fail)); then exit 1; fi
echo "datastore-images ok (${#seen[@]} images)"
