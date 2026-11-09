#!/usr/bin/bash
# Smoke test, run INSIDE the built image: the plugin directories exist with the jars the Iceberg sink needs.
set -euo pipefail
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
d=/kafka/connect/iceberg-sink
[ -d "${d}" ] || fail "${d} missing"
for j in iceberg-kafka-connect iceberg-kafka-connect-transforms iceberg-parquet iceberg-orc iceberg-aws iceberg-aws-bundle hadoop-client-api hadoop-client-runtime; do
    ls "${d}/${j}-"*.jar >/dev/null 2>&1 || fail "jar ${j} missing in ${d}"
done
# Kafka's own client jars must not be inside the plugin directory
if ls "${d}"/kafka-clients-*.jar "${d}"/connect-api-*.jar >/dev/null 2>&1; then fail "kafka-clients or connect-api leaked into the plugin"; fi
[ -d /kafka/connect ] && ls /kafka/connect | grep -qi debezium || fail "no Debezium connector directory under /kafka/connect"
echo "ok: iceberg-sink plugin jars, no kafka-clients, debezium connectors present"
echo "SMOKE PASS"
