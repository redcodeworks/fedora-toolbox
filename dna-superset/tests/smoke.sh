#!/usr/bin/bash
# Smoke test, run INSIDE the built image: the Postgres and Trino drivers import in Superset's environment.
set -euo pipefail
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
/app/.venv/bin/python -c 'import psycopg2, trino.sqlalchemy' || fail "psycopg2 or trino.sqlalchemy not importable in /app/.venv"
/app/.venv/bin/python -c 'import superset' || fail "superset not importable"
echo "ok: psycopg2 and trino drivers import, superset importable"
echo "SMOKE PASS"
