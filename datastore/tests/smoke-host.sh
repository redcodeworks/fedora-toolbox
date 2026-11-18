#!/usr/bin/env bash
# Runtime smoke test of the datastore box, run on the HOST (`just smoke datastore` calls it with the image reference):
# the image runs with its own systemd (podman run --systemd=always, the nearest equivalent of `distrobox create --init`),
# on a throwaway network under the aliases the real box gets. Then: the in-image checks, `datastore setup`/`start` as a
# regular user, the four units, ports, a round trip through each service, a stop and start of the services with /run emptied (the data and the units come back),
# and a backup of the first box restored into a second, fresh one (the migration path). Only the containers and the
# network this script creates are ever removed.
#   smoke-host.sh <image>
set -euo pipefail

image=${1:?usage: smoke-host.sh <image>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=$$
net="ds-smoke-net-${id}"
boxa="ds-smoke-a-${id}"
boxb="ds-smoke-b-${id}"
aliases=(--network-alias pgsql --network-alias postgresql --network-alias valkey --network-alias seaweedfs --network-alias kafka)

fail() {
    echo "SMOKE FAIL: $*" >&2
    dump_logs
    exit 1
}
dump_logs() {
    local b
    for b in "${boxa}" "${boxb}"; do
        podman container exists "${b}" 2>/dev/null || continue
        echo "---- ${b}: failed units and journal tail" >&2
        podman exec "${b}" bash -c 'systemctl --failed --no-legend; journalctl -n 60 --no-pager' >&2 || true
    done
}
cleanup() {
    podman rm -f -t 2 "${boxa}" "${boxb}" >/dev/null 2>&1 || true
    podman network rm "${net}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step() { echo "== $*"; }
ds() { podman exec --user dsuser -e HOME=/home/dsuser "$1" "${@:2}"; } # ds <box> <command...>

start_box() { # name
    podman run -d --name "$1" --systemd=always --network "${net}" "${aliases[@]}" \
        -p 127.0.0.1::5432 -p 127.0.0.1::6379 -p 127.0.0.1::8333 -p 127.0.0.1::9333 -p 127.0.0.1::8888 -p 127.0.0.1::9092 \
        "${image}" /usr/lib/systemd/systemd >/dev/null
    for _ in $(seq 1 60); do
        state=$(podman exec "$1" systemctl is-system-running 2>/dev/null || true)
        [[ "${state}" == running || "${state}" == degraded ]] && break
        sleep 2
    done
    [[ "${state:-}" == running || "${state:-}" == degraded ]] || fail "systemd in $1 never came up (state: ${state:-none})"
    # distrobox gives the box user passwordless sudo; do the same
    podman exec "$1" bash -c 'useradd -m dsuser && echo "dsuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dsuser'
}

wait_for() { # box description command...: retry up to 3 minutes
    local box=$1 what=$2
    shift 2
    for _ in $(seq 1 90); do
        if podman exec --user dsuser -e HOME=/home/dsuser "${box}" bash -c "$*" >/dev/null 2>&1; then
            echo "ok: ${what}"
            return 0
        fi
        sleep 2
    done
    fail "${what}"
}

step "in-image checks"
podman run --rm -v "${here}/smoke.sh:/smoke.sh:ro,z" "${image}" bash /smoke.sh >/dev/null || fail "in-image smoke test"
echo "ok: in-image smoke test"

podman network create "${net}" >/dev/null
step "box A: systemd, setup, start"
start_box "${boxa}"
echo "ok: systemd is PID 1 (state ${state})"
ds "${boxa}" datastore setup >/dev/null
ds "${boxa}" datastore start >/dev/null || fail "datastore start"
for p in 5432 6379 8333 9333 8888 9092; do
    wait_for "${boxa}" "port ${p} open" "exec 3<>/dev/tcp/127.0.0.1/${p}"
done
for s in postgres valkey seaweedfs kafka; do
    podman exec "${boxa}" systemctl is-active --quiet "datastore-${s}.service" || fail "datastore-${s} is not active"
    echo "ok: datastore-${s} active"
done
for p in 5432 6379 8333 9333 8888 9092; do
    hp=$(podman port "${boxa}" "${p}/tcp" | head -n1)
    [[ -n "${hp}" ]] || fail "port ${p} is not published"
    (exec 3<>"/dev/tcp/${hp%:*}/${hp##*:}") 2>/dev/null || fail "published port ${p} (${hp}) does not answer from the host"
done
echo "ok: all six ports answer on the published loopback ports"

step "round trips inside the box"
ds "${boxa}" datastore psql -Atc "create table smoke(i int); insert into smoke values (42); select * from smoke" | grep -qx 42 || fail "postgres round trip"
ds "${boxa}" datastore psql -Atc "show wal_level" | grep -qx logical || fail "wal_level is not logical"
echo "ok: postgres round trip, wal_level logical"
ds "${boxa}" bash -c 'datastore valkey-cli set smoke hello >/dev/null && [ "$(datastore valkey-cli get smoke)" = hello ]' || fail "valkey round trip"
ds "${boxa}" bash -c 'valkey-cli -h 127.0.0.1 get smoke 2>&1 | grep -q NOAUTH' || fail "valkey accepts unauthenticated clients"
echo "ok: valkey round trip with password, unauthenticated refused"
keys=$(ds "${boxa}" datastore secrets show seaweedfs-s3-config)
ak=$(jq -r '.identities[0].credentials[0].accessKey' <<<"${keys}")
sk=$(jq -r '.identities[0].credentials[0].secretKey' <<<"${keys}")
ds "${boxa}" bash -c "
  set -e
  s3() { curl -fsS --aws-sigv4 'aws:amz:us-east-1:s3' --user '${ak}:${sk}' \"\$@\"; }
  s3 -X PUT http://127.0.0.1:8333/smoke >/dev/null
  echo seaweed-ok > /tmp/obj && s3 -X PUT --upload-file /tmp/obj http://127.0.0.1:8333/smoke/obj >/dev/null
  [ \"\$(s3 http://127.0.0.1:8333/smoke/obj)\" = seaweed-ok ]
  ! curl -fsS http://127.0.0.1:8333/smoke/obj >/dev/null 2>&1" || fail "S3 round trip (or anonymous access allowed)"
echo "ok: S3 round trip with the generated keys, anonymous refused"
ds "${boxa}" bash -c "
  set -e
  k=/opt/kafka/bin
  \$k/kafka-topics.sh --bootstrap-server kafka:9092 --create --topic smoke >/dev/null
  echo kafka-ok | \$k/kafka-console-producer.sh --bootstrap-server kafka:9092 --topic smoke
  [ \"\$(\$k/kafka-console-consumer.sh --bootstrap-server kafka:9092 --topic smoke --from-beginning --max-messages 1 --timeout-ms 60000 2>/dev/null)\" = kafka-ok ]" || fail "Kafka round trip through the alias kafka:9092"
echo "ok: Kafka round trip through the alias kafka:9092"

step "other containers reach the box by its aliases"
pgpw=$(ds "${boxa}" datastore secrets show postgresql-password)
vpw=$(ds "${boxa}" datastore secrets show valkey-password)
podman run --rm --network "${net}" -e PGPASSWORD="${pgpw}" -e REDISCLI_AUTH="${vpw}" "${image}" bash -c '
  set -e
  [ "$(psql -h pgsql -U postgres -Atc "select 1")" = 1 ]
  [ "$(valkey-cli -h valkey ping)" = PONG ]
  curl -s -o /dev/null http://seaweedfs:8333/
  (exec 3<>/dev/tcp/kafka/9092)' || fail "aliases pgsql, valkey, seaweedfs or kafka do not answer from another container"
echo "ok: pgsql, valkey, seaweedfs and kafka answer from another container"

step "backup"
ds "${boxa}" datastore backup /home/dsuser/bk --stop >/dev/null || fail "datastore backup --stop"
ds "${boxa}" bash -c 'ls /home/dsuser/bk/postgres-*.sql /home/dsuser/bk/{valkey,seaweed,kafka}-*.tar >/dev/null'
for s in postgres valkey seaweedfs kafka; do podman exec "${boxa}" systemctl is-active --quiet "datastore-${s}.service" || fail "datastore-${s} not restarted after backup --stop"; done
echo "ok: backup wrote a dump and three tars, services are back"

# The box's own restart is not tested by restarting the container: on the hosted runner (rootless podman, published ports on a
# custom network) stopping a container failed in podman's rootless network teardown ("kill network process: permission denied"),
# which has nothing to do with the box. What matters is what a box restart does to the services: all four stop, /run is
# emptied, then they start again from the enabled units. Do exactly that inside the running box.
step "restart (the /run/postgresql gotcha, units and data come back)"
podman exec "${boxa}" bash -c 'systemctl stop datastore-postgres datastore-valkey datastore-seaweedfs datastore-kafka && rm -rf /run/postgresql'
podman exec "${boxa}" test ! -e /run/postgresql || fail "/run/postgresql should be gone before the start"
ds "${boxa}" datastore start >/dev/null || fail "datastore start after the stop"
wait_for "${boxa}" "postgres answers after the restart" "datastore psql -Atc 'select i from smoke' | grep -qx 42"
wait_for "${boxa}" "valkey keeps its key after the restart" "[ \"\$(datastore valkey-cli get smoke)\" = hello ]"
wait_for "${boxa}" "kafka listens again" "exec 3<>/dev/tcp/127.0.0.1/9092"

step "box B: restore the pg_dumpall file into a fresh box (migration path)"
start_box "${boxb}"
dump=$(podman exec "${boxa}" bash -c 'ls /home/dsuser/bk/postgres-*.sql')
podman exec "${boxa}" cat "${dump}" | podman exec -i "${boxb}" bash -c 'cat > /home/dsuser/dump.sql && chown dsuser /home/dsuser/dump.sql'
ds "${boxb}" datastore setup >/dev/null
ds "${boxb}" datastore start postgres >/dev/null || fail "box B: start postgres"
wait_for "${boxb}" "box B postgres is up" "datastore psql -Atc 'select 1' | grep -qx 1"
ds "${boxb}" datastore restore /home/dsuser/dump.sql || fail "box B: restore"
ds "${boxb}" datastore psql -Atc "select i from smoke" | grep -qx 42 || fail "box B: restored table is missing"
echo "ok: the dump restored into a fresh box, and its own postgres password still works"

echo "SMOKE PASS (runtime)"
