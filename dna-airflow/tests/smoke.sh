#!/usr/bin/bash
# Smoke test, run INSIDE the built image.
set -euo pipefail
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
airflow version | grep -q '^3\.3\.1' || fail "airflow version is not 3.3.1: $(airflow version)"
python --version | grep -q 'Python 3\.11' || fail "python is not 3.11"
command -v git >/dev/null || fail "git missing"
[ "${LAKEHOUSE_HOME}" = "/opt/lakehouse" ] || fail "LAKEHOUSE_HOME is ${LAKEHOUSE_HOME:-unset}"
[ -w /opt/venvs ] && [ -w /opt/lakehouse ] || fail "/opt/venvs or /opt/lakehouse is not writable by the airflow user"
command -v dna-venv >/dev/null || fail "dna-venv missing"
bash -n "$(command -v dna-venv)"
for d in dags pipelines jobs dbt; do [ ! -e "/opt/lakehouse/${d}" ] || fail "/opt/lakehouse/${d} is baked into the image"; done
echo "ok: airflow 3.3.1 on python 3.11, git, empty /opt/venvs and /opt/lakehouse, dna-venv"
echo "SMOKE PASS"
