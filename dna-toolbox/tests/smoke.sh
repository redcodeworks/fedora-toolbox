#!/usr/bin/bash
# Smoke test, run INSIDE the built image:
#   podman run --rm -v ./tests/smoke.sh:/smoke.sh:ro <image> bash /smoke.sh
# Fails on the first missing piece.
set -euo pipefail

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

run() {
    local out
    out=$("$@" 2>&1) || fail "'$*' failed: $out"
    echo "ok: $* -> $(head -n1 <<<"$out")"
}

# TODO: one line per tool this toolbox must provide

# A toolbox shares the user's home at runtime: the image must carry nothing user-specific
if [ -d /home ] && [ -n "$(find /home -mindepth 1 -maxdepth 2 2>/dev/null | head -n1)" ]; then
    fail "/home is not empty"
fi
extra=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | tr '\n' ' ')
[ -z "$extra" ] || fail "image defines regular users: $extra"
echo "ok: no user-specific content in /home or /etc/passwd"

# critical tools only (optional.txt packages are never required)
run uv --version
command -v rocminfo >/dev/null || fail "rocminfo missing"
command -v rocm-smi >/dev/null || fail "rocm-smi missing"
echo "ok: uv, rocminfo, rocm-smi"

# the server stack tooling is installed and its shipped files pass the static checks
run dna-stack list
run dna-stack check

# pinned versions are defined and exported (DBR 18 LTS reference)
# shellcheck source=/dev/null
. /usr/share/dna-toolbox/versions.env
[ "${DNA_PYTHON_VERSION}" = "3.12" ] || fail "DNA_PYTHON_VERSION default is ${DNA_PYTHON_VERSION}, expected 3.12"
echo "ok: versions.env (DBR ${DNA_DBR_VERSION}, Spark ${DNA_SPARK_VERSION}, Python ${DNA_PYTHON_VERSION}, Java ${DNA_JAVA_VERSION})"

# conda-forge only: no defaults channel anywhere
channels=$(conda config --show channels 2>&1) || fail "conda config failed: ${channels}"
if grep -qi defaults <<<"${channels}"; then fail "conda lists the defaults channel: ${channels}"; fi
grep -q conda-forge <<<"${channels}" || fail "conda-forge is not a configured channel: ${channels}"
echo "ok: conda channels are conda-forge only"

run mamba --version
run psql --version
run jupyter-lab --version
command -v kcat >/dev/null || fail "kcat missing"
for t in dna-setup dna-lab dna-doctor; do
    command -v "${t}" >/dev/null || fail "${t} missing"
    bash -n "$(command -v "${t}")" || fail "${t} has a syntax error"
done
dna-doctor >/dev/null || fail "dna-doctor failed"
echo "ok: kcat, dna-setup, dna-lab, dna-doctor"
# the pinned DuckDB download is optional: checked only when it was installed
if command -v duckdb >/dev/null; then run duckdb --version; else echo "note: duckdb not installed (optional download)"; fi

echo "SMOKE PASS"
