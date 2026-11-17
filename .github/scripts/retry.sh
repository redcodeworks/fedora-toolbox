#!/usr/bin/env bash
# Run a command until it succeeds, for reads of something this run has just written to the registry (GHCR answers
# `manifest unknown` or `no signatures found` for a short while after a push, copy or signing):
#
#   retry.sh <command> [args...]
#
# RETRY_TRIES (default 8) attempts, RETRY_DELAY (default 8) seconds apart: about a minute in all. The last attempt's output and
# exit status are the command's own. Only use it where "not there yet" is the expected failure; a wrong value must be
# compared by the caller AFTER the read succeeds, so that a real mismatch still fails at once.
set -uo pipefail
tries="${RETRY_TRIES:-8}"
delay="${RETRY_DELAY:-8}"
[[ $# -ge 1 ]] || { echo "usage: retry.sh <command> [args...]" >&2; exit 2; }
n=1
while true; do
    "$@" && exit 0
    status=$?
    if (( n >= tries )); then
        echo "retry.sh: '$1' still failing after ${n} attempts (exit ${status})" >&2
        exit "${status}"
    fi
    echo "retry.sh: attempt ${n}/${tries} of '$1' failed (exit ${status}), retrying in ${delay}s" >&2
    n=$((n + 1))
    sleep "${delay}"
done
