#!/usr/bin/env bash
# Tests for the datastore bundle (datastore-images/): the rendered Quadlets (agreement with images.txt, no [Install], no AutoUpdate,
# loopback ports above 1023, no host paths, no secret values, stable unit, pod, network and volume names), install and uninstall in
# a temporary HOME (idempotent, atomic, never touching volumes or secrets), the commands of bin/datastore (secrets, pins and
# drop-ins, status, the PostgreSQL data major guard, backups, start and stop) and the shape of the bundle files. The tests run the
# bundle from the repository tree and from a copy laid out like the extracted image. podman, systemctl and journalctl are fakes
# on a PATH that holds only bash, coreutils, sed and awk; nothing real is created. Image references come from images.txt, never
# from literals here. Needs: bash. Run: tests/datastore-bundle.sh
# shellcheck disable=SC2034,SC2154
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dsdir="$here/datastore-images"
entry="$dsdir/bin/datastore"
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0
failn=0
rc=0
ok() {
    pass=$((pass + 1))
    echo "ok   $1"
}
bad() {
    failn=$((failn + 1))
    echo "FAIL $1"
    sed 's/^/     /' "$root/out" 2>/dev/null
    echo "     rc=$rc"
}
check() {
    local d=$1
    shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}
has() { grep -qF -- "$1" "$root/out"; }

# ---- the pin file and the rendered Quadlets
rq="$root/quadlets"
list="$dsdir/images.txt"
"$dsdir/lib/render.sh" "$rq" "$dsdir" "$list" >"$root/out" 2>&1
rc=$?
check "render: runs on images.txt" test "$rc" = 0
expected="datastore.pod kafka-data.volume kafka.container kafka.pod lakehouse.network postgresql-data.volume postgresql.container seaweed-data.volume seaweedfs.container valkey-data.volume valkey.container" # C locale order
check "render: exactly the pods, containers, network and volumes of the datastore (no airflow, connect, superset, trino, lakekeeper, dvdrental)" test "$(LC_ALL=C ls "$rq" | tr '\n' ' ')" = "$expected "
for svc in postgresql valkey seaweedfs kafka; do
    ref=$(awk -v n="$svc" '$1 == n {print $2}' "$list")
    tag=${ref#*:}
    tag=${tag%%@*}
    digest=${ref##*@}
    check "pins: $svc Image= in the Quadlet is exactly the reference of images.txt" grep -qx "Image=${ref}" "$rq/$svc.container"
    check "pins: $svc tag is exact (digits, dots, an optional -suffix) and not latest" bash -c "[[ '$tag' =~ ^[0-9]+(\\.[0-9]+)+(-[a-z0-9.]+)?\$ ]] && [ '$tag' != latest ]"
    check "pins: $svc digest is sha256 plus 64 hex" bash -c "[[ '$digest' =~ ^sha256:[0-9a-f]{64}\$ ]]"
    check "pins: the $svc.container has one Image= line and no other image reference" bash -c "[ \$(grep -c '^Image=' '$rq/$svc.container') = 1 ]"
done
check "pins: no Quadlet image is latest, unversioned or from a local registry" bash -c "! grep -hE '^Image=' '$rq'/*.container | grep -E ':latest|localhost/|^Image=[^:]*\$'"
check "no Quadlet has an [Install] section, so nothing starts by itself" bash -c "! grep -l '^\\[Install\\]' '$rq'/*"
check "no stateful unit has AutoUpdate= (no unattended image changes)" bash -c "! grep -l '^AutoUpdate=' '$rq'/*"
check "no host-specific path or user specifier in the Quadlets (/home, %h, /var/home, .local/share)" bash -c "! grep -E '/home/|%h|/var/home|\\.local/share|kevin' '$rq'/*"
check "no secret value in the Quadlets: passwords come from Secret= and *_FILE only" bash -c "! grep -iE '(PASSWORD|SECRET|ACCESS_KEY)=[^/ ]' '$rq'/* | grep -v 'POSTGRES_PASSWORD_FILE=/run/secrets/'; grep -q '^Secret=postgresql-password' '$rq/postgresql.container' && grep -q '^Secret=valkey-password' '$rq/valkey.container' && grep -q '^Secret=seaweedfs-s3-config,type=mount' '$rq/seaweedfs.container'"
check "ports: every PublishPort is bound to 127.0.0.1 and the host port is above 1023" bash -c "grep -h '^PublishPort=' '$rq'/*.pod | awk -F'[=:]' '{ if (\$2 != \"127.0.0.1\" || \$3 < 1024) bad=1 } END { exit bad }' && [ \$(grep -h '^PublishPort=' '$rq'/*.pod | wc -l) = 6 ]"
check "ports: the datastore pod publishes 5432 6379 8333 9333 8889 and kafka 9092" bash -c "for p in 5432:5432 6379:6379 8333:8333 9333:9333 8889:8888; do grep -q \"PublishPort=127.0.0.1:\$p\" '$rq/datastore.pod' || exit 1; done; grep -q 'PublishPort=127.0.0.1:9092:9092' '$rq/kafka.pod'"
check "the pods and containers join the lakehouse network; the dvdrental network is not referenced" bash -c "grep -q '^Network=lakehouse.network' '$rq/datastore.pod' '$rq/kafka.pod' && ! grep -rq dvdrental '$rq'"
check "kafka accepts SIGTERM's exit status 143 as a clean stop (a stopped broker is not a failed unit); the other containers do not need it" bash -c "grep -qx 'SuccessExitStatus=143' '$rq/kafka.container' && ! grep -q 'SuccessExitStatus' '$rq/postgresql.container' '$rq/valkey.container'"
check "seaweedfs: StopTimeout is set (30 to 60 s) and systemd's TimeoutStopSec is longer, so systemd never kills podman before the container's own limit" bash -c "st=\$(sed -n 's/^StopTimeout=//p' '$rq/seaweedfs.container'); ts=\$(sed -n 's/^TimeoutStopSec=//p' '$rq/seaweedfs.container'); [ -n \"\$st\" ] && [ \"\$st\" -ge 30 ] && [ \"\$st\" -le 60 ] && [ \"\$ts\" -gt \"\$st\" ]"
check "seaweedfs 4.x drops privileges itself: the unit sets no User=, UserNS= or :U volume option, and the S3 secret keeps a readable default mode (no mode=0400 or 0600)" bash -c "! grep -qE '^(User|UserNS)=|:U( |,|\$)' '$rq/seaweedfs.container' && ! grep -qE 'Secret=.*mode=0?[46]00' '$rq/seaweedfs.container'"
check "volumes are named podman volumes with the local driver, and the names of existing data stay (postgresql-data valkey-data seaweed-data kafka-data)" bash -c "for v in postgresql seaweed valkey kafka; do grep -qx \"VolumeName=\$v-data\" '$rq'/\$v-data.volume && grep -qx 'Driver=local' '$rq'/\$v-data.volume || exit 1; done"
check "names are stable: pods datastore and kafka, network lakehouse, containers pgsql valkey seaweedfs kafka, secrets as before" bash -c "grep -qx 'PodName=datastore' '$rq/datastore.pod' && grep -qx 'PodName=kafka' '$rq/kafka.pod' && grep -qx 'NetworkName=lakehouse' '$rq/lakehouse.network' && grep -qx 'ContainerName=pgsql' '$rq/postgresql.container' && grep -qx 'ContainerName=valkey' '$rq/valkey.container' && grep -qx 'ContainerName=seaweedfs' '$rq/seaweedfs.container' && grep -qx 'ContainerName=kafka' '$rq/kafka.container'"
check "no sudo, pkexec or run0 in any Quadlet, in bin/datastore, the libraries or the README" bash -c "! grep -E '(sudo|pkexec|run0)' '$rq'/* '$entry' '$dsdir'/lib/* '$dsdir/README.md'"
# render must refuse bad lines
bad_render() { # description, sed expression
    local d=$1 e=$2
    rm -rf "${root:?}/bad" "${root:?}/bad-out"
    mkdir -p "$root/bad"
    sed "$e" "$list" >"$root/bad/images.txt"
    "$dsdir/lib/render.sh" "$root/bad-out" "$dsdir" "$root/bad/images.txt" >"$root/out" 2>&1
    rc=$?
    check "render refuses $d (and writes nothing)" bash -c "[ $rc != 0 ] && [ ! -e '$root/bad-out' ]"
}
pgtag=$(awk '$1 == "postgresql" {print $2}' "$list")
pgtag=${pgtag#*:}
pgtag=${pgtag%%@*}
pg_major=${pgtag%%.*}
pg_suffix=""
[[ "$pgtag" == *-* ]] && pg_suffix="-${pgtag#*-}"
bad_render "a latest tag" 's/^\(valkey [^ ]*\):[^@]*@/\1:latest@/'
bad_render "a floating major tag" "s/^\\(postgresql [^ ]*\\):[^@]*@/\\1:${pg_major}${pg_suffix}@/"
bad_render "a bad digest" 's/^\(kafka .*@sha256:\)[0-9a-f]*/\1abc/'
bad_render "a line without a digest" 's/^\(seaweedfs [^ ]*\)@.*$/\1/'
bad_render "a missing image" '/^kafka /d'
bad_render "an unknown name" 's/^kafka /airflow /'
bad_render "a name listed twice" 's/^valkey /kafka /'
check "render equals an independent sed of the templates: each Quadlet is the template with only the placeholder replaced" bash -c "
  rm -rf '$root/ind'; mkdir -p '$root/ind'; cp '$dsdir'/quadlets/* '$root/ind/'
  for svc in postgresql valkey seaweedfs kafka; do
    ref=\$(awk -v n=\$svc '\$1 == n {print \$2}' '$list'); up=\$(echo \$svc | tr a-z A-Z)
    sed -i \"s|@\${up}_IMAGE@|\$ref|g\" '$root/ind'/*.container
  done
  diff -r '$root/ind' '$rq'"
check "every placeholder in the templates is one of the four image placeholders" bash -c "! grep -ho '@[A-Z_]*@' '$dsdir'/quadlets/* | sort -u | grep -vxE '@(POSTGRESQL|VALKEY|SEAWEEDFS|KAFKA)_IMAGE@'"
if [ -x /usr/libexec/podman/quadlet ]; then
    QUADLET_UNIT_DIRS="$rq" /usr/libexec/podman/quadlet --user --dryrun >"$root/out" 2>&1
    rc=$?
    check "podman's Quadlet generator accepts the rendered units (dry run) and makes a service for each" bash -c "[ $rc = 0 ] && [ \$(grep -c '^---.*service---' '$root/out') = 11 ]"
else
    echo "skip podman's Quadlet generator is not installed"
fi

# ---- stubs for the commands
bin="$root/bin"
sysbin="$root/sysbin"
mkdir -p "$bin" "$sysbin" "$root/secrets" "$root/home"
# the PATH of every run holds only these (the bundle's dependencies) and the fakes below
for c in bash sh env cat grep awk sed cut tr date head sort dirname basename wc chmod printf mkdir mktemp mv rm ls touch base64 tee cmp id uname true tail rmdir stat readlink sha256sum cp; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
rm -f "${sysbin:?}/id"
export LOG="$root/log" HOME="$root/home" DATASTORE_VENDOR_DIR="$root/none" SECRETS="$root/secrets" VOLS="$root/vols"
unset XDG_CONFIG_HOME XDG_STATE_HOME DATASTORE_UJUST DATASTORE_IMAGES DATASTORE_USER_DIR DATASTORE_STATE_DIR
uh="$root/home/.config/containers/systemd"
state="$root/home/.local/state/datastore"
cat >"$bin/podman" <<'F'
#!/usr/bin/env bash
echo "podman $*" >>"$LOG"
case "$1 $2" in
    "secret inspect") [ -f "$SECRETS/$3" ]; exit $? ;;
    "secret create")
        [ "${FAKE_SECRET_FAIL:-}" = "$3" ] && { cat >/dev/null; exit 1; }
        cat >"$SECRETS/$3"; exit 0 ;;
    "volume exists") [ -d "$VOLS/$3" ]; exit $? ;;
    "volume inspect") echo "$VOLS/$3/_data"; exit 0 ;;
    "volume export")
        [ "${FAKE_EXPORT_FAIL:-}" = "$3" ] && { echo partial >"${5}"; exit 1; }
        [ "${FAKE_EXPORT_SIGNAL:-}" = "$3" ] && { echo partial >"${5}"; kill -TERM "$PPID"; exit 0; }
        echo "tar of $3" >"${5}"; exit 0 ;;
    "info --format") echo "${FAKE_GRAPHROOT:-/mnt/data/containers/storage}"; exit 0 ;;
    "unshare cat") cat "$3" 2>/dev/null; exit $? ;;
    "unshare du") echo "12M	$4"; exit 0 ;;
    "exec pgsql") echo "-- pg_dumpall output"; exit 0 ;;
    "pull "*) [ "${FAKE_PULL_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
esac
case "$1" in
    inspect)
        c=$2
        case "$*" in
            *State.Status*) for r in $RUNNING; do [ "$r" = "$c" ] && { echo running; exit 0; }; done; exit 1 ;;
            *ImageName*) for r in $RUNNING; do [ "$r" = "$c" ] && { echo "running-image-of-$c"; exit 0; }; done; exit 1 ;;
        esac ;;
esac
exit 0
F
cat >"$bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
[ "$1" = --user ] || exit 99
case "$2" in
    is-active) for a in $ACTIVE; do [ "$a" = "$3" ] && { echo active; exit 0; }; done; echo inactive; exit 3 ;;
    start) [ "${FAKE_START_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
    stop|daemon-reload) exit 0 ;;
esac
exit 0
F
cat >"$bin/journalctl" <<'F'
#!/usr/bin/env bash
echo "journalctl $*" >>"$LOG"
exit 0
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
[ "$1" = -u ] && { echo "${FAKE_UID:-1000}"; exit 0; }
exit 0
F
chmod +x "$bin"/*
export RUNNING="" ACTIVE=""
reset0() { # a clean home, nothing installed
    rm -rf "${root:?}/secrets" "${root:?}/vols" "${root:?}/home/.config" "${root:?}/home/.local"
    mkdir -p "$root/secrets" "$root/vols" "$root/home"
    : >"$LOG"
    export RUNNING="" ACTIVE=""
    unset FAKE_UID FAKE_SECRET_FAIL FAKE_EXPORT_SIGNAL FAKE_EXPORT_FAIL FAKE_PULL_FAIL FAKE_START_FAIL FAKE_GRAPHROOT
}
run() { # args of bin/datastore; the entry script of $ENTRY (default: the repository tree)
    PATH="$bin:$sysbin" "${ENTRY:-$entry}" "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
reset() { # a clean home with the units installed, as after `datastore install`
    reset0
    run install
    : >"$LOG"
}
mkvol() { mkdir -p "$VOLS/$1/_data"; }
allsecrets() { for s in postgresql-password valkey-password seaweedfs-s3-config; do echo x >"$SECRETS/$s"; done; }

# pins derived from images.txt: the shipped postgresql reference, and tags of the same, an older and a newer major
shipped_pg=$(awk '$1 == "postgresql" {print $2}' "$list")
pg_path=${shipped_pg%%@*}
pg_path=${pg_path%:*}
pg_oldmajor=$((pg_major - 1))
pg_pin="${pg_major}.0.1${pg_suffix}"
pg_pin2="${pg_major}.0.2${pg_suffix}"
pg_next="$((pg_major + 1)).0.1${pg_suffix}"
pg_old="${pg_oldmajor}.9.9${pg_suffix}"
# ---- shape
reset
run --help
check "datastore --help: usage, exit 0, names start stop status logs" bash -c "[ $rc = 0 ] && grep -q 'start' '$root/out' && grep -q 'status' '$root/out' && grep -q 'logs' '$root/out'"
reset
run setup --help
check "datastore-setup --help: usage, exit 0, names every flag" bash -c "[ $rc = 0 ] && for f in --pin --unpin --update --backup --status --yes --no; do grep -q -- \$f '$root/out' || exit 1; done"
reset
FAKE_UID=0 run status
check "datastore: refuses root" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out'"
reset
FAKE_UID=0 run setup --yes
check "datastore-setup: refuses root, creates nothing" bash -c "[ $rc = 1 ] && [ -z \"\$(ls '$SECRETS')\" ]"
reset
run nosuch
check "datastore: an unknown command exits 2" test "$rc" = 2

# ---- datastore-setup: secrets
reset
run setup --yes
check "secrets fresh: the three missing secrets are created through stdin, none printed" bash -c "[ $rc = 0 ] && for s in postgresql-password valkey-password seaweedfs-s3-config; do [ -s '$SECRETS'/\$s ] || exit 1; done && ! grep -q 'secret create postgresql-password -' /dev/null; grep -q 'podman secret create postgresql-password -' '$LOG'"
check "secrets fresh: no secret value appears in the output or the call log" bash -c "for s in postgresql-password valkey-password seaweedfs-s3-config; do while read -r v; do [ -z \"\$v\" ] || { grep -qF -- \"\$v\" '$root/out' '$LOG' && exit 1; }; done < '$SECRETS'/\$s; done; exit 0"
check "secrets fresh: the S3 config is a generated identities JSON with an admin and credentials, random each time" bash -c "grep -q '\"identities\"' '$SECRETS/seaweedfs-s3-config' && grep -q '\"accessKey\":\"[A-Za-z0-9]\\{20\\}\"' '$SECRETS/seaweedfs-s3-config' && grep -q '\"secretKey\":\"[A-Za-z0-9]\\{40\\}\"' '$SECRETS/seaweedfs-s3-config'"
check "secrets fresh: the generated passwords are 32 characters of letters and digits" bash -c "[ \"\$(tr -d '\\n' <'$SECRETS/postgresql-password' | wc -c)\" = 32 ] && ! grep -q '[^A-Za-z0-9]' <(tr -d '\\n' <'$SECRETS/valkey-password')"
check "secrets fresh: an undo line names podman secret rm" has "podman secret rm"
cp "$SECRETS/postgresql-password" "$root/pg.before"
: >"$LOG"
run setup --yes
check "secrets existing: all present means nothing to do, no create call, and nothing overwritten" bash -c "[ $rc = 0 ] && grep -q 'All secrets exist already' '$root/out' && ! grep -q 'secret create' '$LOG' && cmp -s '$root/pg.before' '$SECRETS/postgresql-password'"
reset
echo old >"$SECRETS/valkey-password"
run setup --yes
check "secrets partly existing: only the missing ones are created, the existing one is untouched" bash -c "[ \"\$(cat '$SECRETS/valkey-password')\" = old ] && [ -s '$SECRETS/postgresql-password' ] && ! grep -q 'secret create valkey-password' '$LOG'"
reset
FAKE_SECRET_FAIL=valkey-password run setup --yes
check "secrets failure: the failing one is reported, the others are still created, exit 1" bash -c "[ $rc = 1 ] && grep -q 'Failed: podman secret create valkey-password' '$root/out' && [ -s '$SECRETS/postgresql-password' ]"
reset
run setup --no
check "secrets --no: the plan only, nothing created" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && [ -z \"\$(ls '$SECRETS')\" ]"
# a lost postgresql-password with an existing data volume: a NEW password would not match the database (it keeps the one it was created with)
reset
mkvol postgresql-data
echo old >"$SECRETS/valkey-password"
echo x >"$SECRETS/seaweedfs-s3-config"
run setup --yes
check "secrets: postgresql-password missing while postgresql-data exists: NOT created, exit 1, the three ways out are named" bash -c "[ $rc = 1 ] && [ ! -e '$SECRETS/postgresql-password' ] && grep -q 'Not creating postgresql-password' '$root/out' && grep -q 'put the OLD password back' '$root/out' && grep -q 'ALTER USER' '$root/out' && grep -q 'setup --backup' '$root/out'"
reset
mkvol postgresql-data
run setup --yes
check "secrets: with the pg volume present the OTHER missing secrets are still created (valkey, seaweedfs), the exit is 1" bash -c "[ $rc = 1 ] && [ ! -e '$SECRETS/postgresql-password' ] && [ -s '$SECRETS/valkey-password' ] && [ -s '$SECRETS/seaweedfs-s3-config' ]"
reset
mkvol postgresql-data
echo x >"$SECRETS/valkey-password"
echo x >"$SECRETS/seaweedfs-s3-config"
run setup --yes
check "secrets: the pg password is the only one missing and the volume exists: nothing is created at all, exit 1" bash -c "[ $rc = 1 ] && ! grep -q 'secret create' '$LOG'"
reset
mkvol valkey-data
mkvol seaweed-data
run setup --yes
check "secrets: volumes of valkey or seaweedfs do not block their secrets (only PostgreSQL keeps a password in its data)" bash -c "[ $rc = 0 ] && [ -s '$SECRETS/postgresql-password' ] && [ -s '$SECRETS/valkey-password' ]"
reset
run setup --yes
cp "$SECRETS/postgresql-password" "$root/pg1"
run setup --yes
check "secrets run twice on a fresh machine: the second run changes nothing (no create call, the password is the same)" bash -c "[ $rc = 0 ] && cmp -s '$root/pg1' '$SECRETS/postgresql-password' && grep -q 'All secrets exist already' '$root/out'"
reset
FAKE_GRAPHROOT="$root/home/.local/share/containers/storage" run setup --no
check "storage: a graphroot under the home is warned about (not backed up, how to move it)" bash -c "grep -q 'inside your home' '$root/out' && grep -q 'storage.conf' '$root/out'"
reset
run setup --no
check "storage: a graphroot outside the home is not warned about" bash -c "! grep -q 'inside your home' '$root/out'"

# ---- pins and drop-ins
dropin="$root/home/.config/containers/systemd/postgresql.container.d/10-image.conf"
shipped_pg=$(sed -n 's/^Image=//p' "$rq/postgresql.container")
reset
run setup --pin postgresql=$pg_pin
check "pin: writes the drop-in with [Container] Image=<path>:<tag> in the same major, reloads systemd, prints the undo" bash -c "[ $rc = 0 ] && grep -qx '\\[Container\\]' '$dropin' && grep -qx 'Image=${pg_path}:${pg_pin}' '$dropin' && grep -q -- '--unpin postgresql' '$root/out' && grep -q 'systemctl --user daemon-reload' '$LOG'"
: >"$LOG"
run setup --pin postgresql=$pg_pin
check "pin again: already done, no reload" bash -c "grep -q 'Already done' '$root/out' && ! grep -q daemon-reload '$LOG'"
run setup --pin postgresql=$pg_next
check "pin: a different major is refused (dump and restore by hand), the drop-in keeps its old content" bash -c "[ $rc = 1 ] && grep -q 'major' '$root/out' && grep -qx 'Image=${pg_path}:${pg_pin}' '$dropin'"
run setup --pin postgresql=latest
check "pin: latest or a floating tag is refused (exit 2)" test "$rc" = 2
run setup --pin nosuch=1.2
check "pin: an unknown service exits 2" test "$rc" = 2
run setup --pin postgresql
check "pin: a missing =TAG exits 2" test "$rc" = 2
run setup --pin postgresql=$pg_pin2 --no
check "pin --no: the plan only, the drop-in is unchanged" bash -c "grep -q 'Plan only' '$root/out' && grep -qx 'Image=${pg_path}:${pg_pin}' '$dropin'"
run setup --status
check "status: shows the shipped pin, the user override and the effective major" bash -c "grep -qF 'shipped $shipped_pg' '$root/out' && grep -q 'override ${pg_path}:${pg_pin}' '$root/out' && grep -q 'image major: $pg_major' '$root/out'"
run setup --unpin postgresql
check "unpin: removes the drop-in and its directory, reloads" bash -c "[ $rc = 0 ] && [ ! -e '$dropin' ] && [ ! -d '$(dirname "$dropin")' ]"
run setup --unpin postgresql
check "unpin again: already done" bash -c "[ $rc = 0 ] && grep -q 'already done' '$root/out'"
run setup --unpin nosuch
check "unpin: an unknown service exits 2" test "$rc" = 2

# ---- the data-version guard and status
reset
allsecrets
mkvol postgresql-data
mkdir -p "$VOLS/postgresql-data/_data/pgdata"
echo $pg_oldmajor >"$VOLS/postgresql-data/_data/pgdata/PG_VERSION"
run start
check "guard: PostgreSQL data of an older major and an image of the pinned major refuse to start with the dump and restore message; nothing is started" bash -c "[ $rc = 1 ] && grep -q 'data volume is PostgreSQL $pg_oldmajor' '$root/out' && grep -q 'dump and restore' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
run setup --status
check "status: shows the data major next to the image major" bash -c "grep -q 'PostgreSQL data major: $pg_oldmajor; image major: $pg_major' '$root/out'"
run setup --pin postgresql=$pg_old
check "guard: pinning the old major is refused too (the major of the shipped pin stays)" test "$rc" = 1
echo $pg_major >"$VOLS/postgresql-data/_data/pgdata/PG_VERSION"
run start
check "guard: data of the same major starts" bash -c "[ $rc = 0 ] && grep -q 'systemctl --user start datastore-pod.service' '$LOG'"
reset
allsecrets
run start
check "guard: a new volume without a cluster is no obstacle" bash -c "[ $rc = 0 ] && grep -q 'systemctl --user start datastore-pod.service' '$LOG'"

# ---- datastore start and stop
reset
run start
check "start: missing secrets: 'run datastore setup first', exit 1, nothing started" bash -c "[ $rc = 1 ] && grep -q 'datastore setup first' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
reset
allsecrets
run start
check "start (default target datastore): systemctl --user start datastore-pod.service, no kafka, no pull, no sudo" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && ! grep -q 'kafka-pod' '$LOG' && ! grep -q 'pull' '$LOG' && ! grep -q sudo '$LOG'"
: >"$LOG"
ACTIVE="datastore-pod.service" run start
check "start: an already running pod is a no-op with a note" bash -c "[ $rc = 0 ] && grep -q 'already running' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
reset
run start kafka
check "start kafka: needs no secrets, starts only kafka-pod.service" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user start kafka-pod.service' '$LOG' && ! grep -q 'datastore-pod' '$LOG'"
reset
allsecrets
run start all
check "start all: both pods" bash -c "grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && grep -qx 'systemctl --user start kafka-pod.service' '$LOG'"
reset
run start nosuch
check "start: an unknown target exits 2" test "$rc" = 2
reset
allsecrets
FAKE_START_FAIL=1 run start
check "start: a failing systemctl is reported and exits 1, naming the journal" bash -c "[ $rc = 1 ] && grep -q 'journalctl --user -u datastore-pod.service' '$root/out'"
reset
ACTIVE="datastore-pod.service kafka-pod.service"
export ACTIVE
run stop all
check "stop all: stops both pods, only systemctl --user stop, never a volume removal or reset" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user stop datastore-pod.service' '$LOG' && grep -qx 'systemctl --user stop kafka-pod.service' '$LOG' && ! grep -qE 'volume rm|system reset|podman rm' '$LOG'"
reset
run stop
check "stop: a pod that is not running is a no-op with a note" bash -c "[ $rc = 0 ] && grep -q 'not running' '$root/out' && ! grep -q 'systemctl --user stop' '$LOG'"
reset
ACTIVE="kafka-pod.service"
export ACTIVE
run stop kafka
check "stop kafka: only kafka-pod.service" bash -c "grep -qx 'systemctl --user stop kafka-pod.service' '$LOG' && ! grep -q datastore-pod '$LOG'"
reset
run stop nosuch
check "stop: an unknown target exits 2" test "$rc" = 2
reset
run logs postgresql
check "logs: journalctl --user -u postgresql.service, bounded to 200 lines" bash -c "[ $rc = 0 ] && grep -qx 'journalctl --user -u postgresql.service -n 200 --no-pager' '$LOG'"
reset
run logs nosuch
check "logs: an unknown service exits 2" test "$rc" = 2
reset
run logs
check "logs: no service exits 2" test "$rc" = 2
reset
ACTIVE="datastore-pod.service"
RUNNING="pgsql valkey"
export ACTIVE RUNNING
run status
check "status: one screen with each pod, container, its state, the running image against the shipped pin, the ports and the secret state" bash -c "[ $rc = 0 ] && grep -q 'datastore-pod.service *active' '$root/out' && grep -q 'kafka-pod.service *inactive' '$root/out' && grep -q 'pgsql *running' '$root/out' && grep -q 'running-image-of-pgsql; pin $shipped_pg' '$root/out' && grep -q 'kafka *kafka *-' '$root/out' && grep -q '127.0.0.1: 5432' '$root/out' && grep -q 'Missing secrets: postgresql-password valkey-password seaweedfs-s3-config' '$root/out'"

# ---- update
reset
run setup --update --no
check "update --no: prints the pins and says back up first, pulls nothing" bash -c "[ $rc = 0 ] && grep -q 'Back up first' '$root/out' && grep -qF '$shipped_pg' '$root/out' && ! grep -q 'podman pull' '$LOG'"
reset
ACTIVE="datastore-pod.service"
export ACTIVE
run setup --update --yes
check "update --yes: pulls the four pinned images (digest included) and does NOT restart or stop a running pod, and says so" bash -c "[ $rc = 0 ] && [ \$(grep -c '^podman pull' '$LOG') = 4 ] && grep -qF 'podman pull $shipped_pg' '$LOG' && ! grep -qE 'systemctl --user (start|stop|restart)' '$LOG' && grep -q 'was NOT restarted' '$root/out'"
reset
FAKE_PULL_FAIL=1 run setup --update --yes
check "update: a failing pull exits 1" test "$rc" = 1
reset
run setup --update
check "update without --yes and no terminal: asks, default no, pulls nothing" bash -c "! grep -q 'podman pull' '$LOG'"

# ---- backup
bk="$root/backup"
reset
mkvol postgresql-data
mkvol valkey-data
mkvol seaweed-data
mkvol kafka-data
run setup --backup "$bk"
check "backup, everything stopped: one tar per existing volume with the date, files private, exit 0" bash -c "[ $rc = 0 ] && for v in postgresql-data valkey-data seaweed-data kafka-data; do ls '$bk'/\$v-[0-9]*.tar >/dev/null || exit 1; done && [ \$(stat -c %a '$bk'/postgresql-data-*.tar) = 600 ]"
check "backup: says the volumes are not covered by snapper or borg and how to restore" bash -c "grep -q 'NOT covered by snapper or borg' '$root/out' && grep -q 'podman volume import' '$root/out'"
check "backup: no timer, no pod started or stopped when nothing ran" bash -c "! grep -qE 'systemctl --user (start|stop)' '$LOG'"
reset
mkvol postgresql-data
mkvol valkey-data
ACTIVE="datastore-pod.service"
export ACTIVE
run setup --backup "$bk-2"
check "backup, pod running: refused without --stop (Valkey, SeaweedFS, Kafka need it stopped), nothing written" bash -c "[ $rc = 1 ] && grep -q 'Refused' '$root/out' && grep -q -- '--stop' '$root/out' && [ ! -d '$bk-2' ]"
: >"$LOG"
run setup --backup "$bk-2" --stop
check "backup --stop: stops the pod, exports, starts it again; PostgreSQL volume exported too while stopped" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user stop datastore-pod.service' '$LOG' && grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && ls '$bk-2'/postgresql-data-*.tar '$bk-2'/valkey-data-*.tar >/dev/null"
reset
mkvol postgresql-data
ACTIVE="datastore-pod.service"
export ACTIVE
run setup --backup "$bk-3"
check "backup, only PostgreSQL exists and the pod runs: an online pg_dumpall into a .sql file, no pod stop needed" bash -c "[ $rc = 0 ] && ls '$bk-3'/postgresql-[0-9]*.sql >/dev/null && grep -q 'podman exec pgsql pg_dumpall -U postgres' '$LOG' && ! grep -q 'systemctl --user stop' '$LOG'"
reset
mkvol kafka-data
ACTIVE="kafka-pod.service"
export ACTIVE
run setup --backup "$bk-4"
check "backup: a running Kafka pod is refused without --stop" bash -c "[ $rc = 1 ] && grep -q 'kafka-pod.service' '$root/out'"
reset
mkvol valkey-data
FAKE_EXPORT_FAIL=valkey-data run setup --backup "$bk-5"
check "backup: a failing export is reported, the partial file removed, exit 1" bash -c "[ $rc = 1 ] && grep -q 'Failed: podman volume export valkey-data' '$root/out' && ! ls '$bk-5'/valkey-data-*.tar 2>/dev/null"
# idempotency: a second backup (even in the same second) keeps the first; a failing export never deletes a good backup; an interrupted --stop run starts the pod again
reset
mkvol valkey-data
mkvol seaweed-data
bk8="$root/backup-8"
run setup --backup "$bk8"
run setup --backup "$bk8"
check "backup twice: both runs keep their files (unique names, nothing overwritten), no .part left" bash -c "[ \$(ls '$bk8'/valkey-data-*.tar | wc -l) = 2 ] && [ \$(ls '$bk8'/seaweed-data-*.tar | wc -l) = 2 ] && ! ls '$bk8'/*.part 2>/dev/null"
first=$(ls "$bk8"/valkey-data-*.tar | head -n1)
sum=$(cksum <"$first")
FAKE_EXPORT_FAIL=valkey-data run setup --backup "$bk8"
check "backup: a failing second export keeps every earlier backup byte for byte and leaves no .part, exit 1" bash -c "[ $rc = 1 ] && [ \$(ls '$bk8'/valkey-data-*.tar | wc -l) = 2 ] && [ \"\$(cksum <'$first')\" = '$sum' ] && ! ls '$bk8'/*.part 2>/dev/null && grep -q 'earlier backup is untouched' '$root/out'"
reset
mkvol valkey-data
mkvol seaweed-data
ACTIVE="datastore-pod.service"
export ACTIVE
: >"$LOG"
bk9="$root/backup-9"
FAKE_EXPORT_SIGNAL=valkey-data run setup --backup "$bk9" --stop
check "backup --stop interrupted (SIGTERM during an export): the pod this run stopped is started again, the partial file is removed, the exit is not 0" bash -c "[ $rc != 0 ] && grep -qx 'systemctl --user stop datastore-pod.service' '$LOG' && grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && ! ls '$bk9'/*.part '$bk9'/valkey-data-*.tar 2>/dev/null"
reset
mkvol valkey-data
ACTIVE="datastore-pod.service"
export ACTIVE
: >"$LOG"
bk10="$root/backup-10"
FAKE_START_FAIL=0 FAKE_EXPORT_FAIL=valkey-data run setup --backup "$bk10" --stop
check "backup --stop with a failing export: the pod is started again (only the one this run stopped), exit 1" bash -c "[ $rc = 1 ] && [ \$(grep -c '^systemctl --user start datastore-pod.service' '$LOG') = 1 ] && ! grep -qE '(start|stop) kafka-pod' '$LOG'"
unset ACTIVE
reset
run setup --backup "$bk-6"
check "backup with no volumes: nothing to do, exit 0, no directory created" bash -c "[ $rc = 0 ] && grep -q 'nothing to back up' '$root/out' && [ ! -d '$bk-6' ]"
reset
mkvol valkey-data
run setup --backup "$bk-7" --no
check "backup --no: the plan only, nothing written" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && [ ! -d '$bk-7' ]"

# ---- install and uninstall (a temporary HOME, fake systemctl and podman)
reset0
run install
check "install: exit 0, every rendered file is placed in the user Quadlet directory byte for byte, nothing else is there" bash -c "[ $rc = 0 ] && diff -r '$rq' '$uh' && [ \$(ls -A '$uh' | wc -l) = 11 ]"
check "install: runs systemctl --user daemon-reload, starts nothing, creates no volume or secret, needs no sudo" bash -c "grep -qx 'systemctl --user daemon-reload' '$LOG' && ! grep -qE 'systemctl --user (start|stop|enable|restart)|volume create|secret create|sudo' '$LOG'"
check "install: prints how to undo it and what comes next" bash -c "grep -q 'undo: datastore uninstall' '$root/out' && grep -q 'datastore setup' '$root/out'"
check "install: records what it installed (sha256 and name, one line per file)" bash -c "[ \$(wc -l <'$state/installed') = 11 ] && grep -qE '^[0-9a-f]{64}  postgresql.container\$' '$state/installed'"
check "install: leaves no staging directory or temporary file behind" bash -c "! ls -A '$root/home/.config/containers' | grep -q stage && ! ls -A '$uh' | grep -q tmp-"
inodes=$(stat -c '%i' "$uh"/*)
: >"$LOG"
run install
check "install again: idempotent, every file unchanged and not rewritten, exit 0" bash -c "[ $rc = 0 ] && ! grep -qE 'install |update ' '$root/out' && [ \"\$(stat -c '%i' '$uh'/*)\" = \"$inodes\" ] && diff -r '$rq' '$uh'"
reset0
run install --no
check "install --no: shows the plan and writes nothing (no units, no record, no reload)" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && [ ! -e '$uh' ] && [ ! -e '$state' ] && ! grep -q daemon-reload '$LOG'"
reset0
FAKE_UID=0 run install
check "install: refuses root, writes nothing" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out' && [ ! -e '$uh' ]"
reset0
mkdir -p "$uh"
echo "mine" >"$uh/postgresql.container"
run install
check "install: a file of the same name that this tool did not install is refused (exit 1), nothing is overwritten or placed" bash -c "[ $rc = 1 ] && grep -q 'postgresql.container' '$root/out' && grep -qx mine '$uh/postgresql.container' && [ \$(ls '$uh' | wc -l) = 1 ] && [ ! -e '$state/installed' ]"
run install --force
check "install --force: overwrites it" bash -c "[ $rc = 0 ] && diff -r '$rq' '$uh'"
reset
echo "# my edit" >>"$uh/kafka.container"
run install
check "install: a unit edited after the install is refused, not overwritten" bash -c "[ $rc = 1 ] && grep -q '# my edit' '$uh/kafka.container'"
reset
sed -i 's/^TimeoutStartSec=.*/TimeoutStartSec=1/' "$uh/valkey.container"
: >"$LOG"
run install --force
check "install --force restores an edited unit" bash -c "[ $rc = 0 ] && diff -r '$rq' '$uh'"
# a newer bundle: a changed image reference updates the placed units; a removed unit file is removed when unchanged
reset
mkdir -p "$root/b2"
sed 's/^\(kafka [^ ]*\):[^@]*@/\1:9.9.9@/' "$list" >"$root/b2/images.txt"
: >"$LOG"
DATASTORE_IMAGES="$root/b2/images.txt" run install
check "install of a bundle with another pin: only the changed unit is updated, the record follows" bash -c "[ $rc = 0 ] && grep -q ':9.9.9@' '$uh/kafka.container' && grep -E '^ *update +kafka.container' '$root/out' && grep -E '^ *unchanged +valkey.container' '$root/out' && grep -qE \"^\$(sha256sum <'$uh/kafka.container' | cut -d' ' -f1)  kafka.container\\\$\" '$state/installed'"
reset
echo "0000000000000000000000000000000000000000000000000000000000000000  gone.container" >>"$state/installed"
echo x >"$uh/gone.container"
sum=$(sha256sum <"$uh/gone.container" | cut -d' ' -f1)
sed -i "s/^0000.*gone.container/$sum  gone.container/" "$state/installed"
run install
check "install: a unit of an earlier bundle that is gone from this one is removed when unchanged" bash -c "[ ! -e '$uh/gone.container' ] && grep -q 'no longer in the bundle' '$root/out' && ! grep -q gone.container '$state/installed'"
reset
sed 's/^valkey .*/valkey docker.io\/valkey\/valkey:latest@sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$list" >"$root/b2/images.txt"
rm -rf "${uh:?}"
rm -rf "${state:?}"
DATASTORE_IMAGES="$root/b2/images.txt" run install
check "install: a bad images.txt (latest tag) places nothing and exits 1" bash -c "[ $rc = 1 ] && [ ! -e '$uh' ] && [ ! -e '$state' ]"
# a broken bundle copy: [Install], a renamed volume, a renamed pod
mkcopy() {
    rm -rf "${root:?}/copy"
    mkdir -p "$root/copy"
    cp -R "$dsdir/bin" "$dsdir/lib" "$dsdir/quadlets" "$dsdir/images.txt" "$root/copy/"
}
mkcopy
printf '\n[Install]\nWantedBy=default.target\n' >>"$root/copy/quadlets/postgresql.container"
reset0
ENTRY="$root/copy/bin/datastore" run install
check "install: a unit with an [Install] section fails the checks, nothing is placed (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'Install' '$root/out' && [ ! -e '$uh' ]"
mkcopy
sed -i 's/^VolumeName=.*/VolumeName=other-data/' "$root/copy/quadlets/valkey-data.volume"
reset0
ENTRY="$root/copy/bin/datastore" run install
check "install: a renamed volume fails the checks (existing data would be orphaned), nothing is placed" bash -c "[ $rc = 1 ] && grep -q 'valkey-data' '$root/out' && [ ! -e '$uh' ]"
mkcopy
sed -i 's/^PodName=datastore/PodName=ds/' "$root/copy/quadlets/datastore.pod"
reset0
ENTRY="$root/copy/bin/datastore" run install
check "install: a renamed pod fails the checks" bash -c "[ $rc = 1 ] && grep -q 'PodName=datastore' '$root/out' && [ ! -e '$uh' ]"
# the bundle as extracted from the image (bin, lib, quadlets, images.txt, nothing else), run through a symlink too
mkcopy
ln -s "$root/copy/bin/datastore" "$root/link"
reset0
ENTRY="$root/link" run install
check "install from a copy laid out like the extracted image, started through a symlink: the same units" bash -c "[ $rc = 0 ] && diff -r '$rq' '$uh'"
ENTRY="$root/copy/bin/datastore" run render "$root/render-out"
check "render DIR: writes the rendered units and nothing else" bash -c "[ $rc = 0 ] && diff -r '$rq' '$root/render-out'"
run render
check "render without a directory exits 2" test "$rc" = 2
reset0
mkdir -p "$root/vendor"
touch "$root/vendor/datastore.pod"
DATASTORE_VENDOR_DIR="$root/vendor" run install
check "install: units of the same names shipped under /usr are noted, and the user copies are used" bash -c "[ $rc = 0 ] && grep -q 'also ships units of the same names' '$root/out'"
if [ -x /usr/libexec/podman/quadlet ]; then
    reset0
    run install
    QUADLET_UNIT_DIRS="$uh" /usr/libexec/podman/quadlet --user --dryrun >"$root/out" 2>&1
    rc=$?
    check "the installed directory is accepted by podman's Quadlet generator" test "$rc" = 0
    # Quadlet takes the first directory of its search path for a name; the user directory comes before /usr/share/containers/systemd/users
    mkdir -p "$root/v1" "$root/v2"
    printf '[Container]\nImage=example.invalid/a:1\nContainerName=dup\n' >"$root/v1/dup.container"
    printf '[Container]\nImage=example.invalid/b:2\nContainerName=dup\n' >"$root/v2/dup.container"
    QUADLET_UNIT_DIRS="$root/v1:$root/v2" /usr/libexec/podman/quadlet --user --dryrun >"$root/out" 2>&1
    rc=$?
    check "Quadlet: a unit name that exists in two search directories is generated once, from the first" bash -c "[ \$(grep -c '^---dup.service---' '$root/out') = 1 ] && grep -q 'example.invalid/a:1' '$root/out' && ! grep -q 'example.invalid/b:2' '$root/out'"
fi
reset
run uninstall --no
check "uninstall --no: the plan only, every file stays" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && diff -r '$rq' '$uh' && [ -f '$state/installed' ]"
mkdir -p "$uh/postgresql.container.d"
echo '[Container]' >"$uh/postgresql.container.d/10-image.conf"
echo "keep me" >"$uh/mine.container"
: >"$LOG"
mkvol postgresql-data
allsecrets
run uninstall
check "uninstall: removes exactly the installed files, keeps a foreign unit and the user's pin drop-in, removes the record, reloads systemd" bash -c "[ $rc = 0 ] && [ \"\$(ls -A '$uh' | tr '\\n' ' ')\" = 'mine.container postgresql.container.d ' ] && [ ! -e '$state' ] && grep -qx 'systemctl --user daemon-reload' '$LOG'"
check "uninstall: never removes a volume or a secret, prints the commands for doing it on purpose, and the undo" bash -c "! grep -qE 'volume rm|secret rm|system reset' '$LOG' && [ -d '$VOLS/postgresql-data' ] && [ -f '$SECRETS/postgresql-password' ] && grep -q 'podman volume rm postgresql-data' '$root/out' && grep -q 'podman secret rm' '$root/out' && grep -q 'undo: datastore install' '$root/out' && grep -q 'image pins stay' '$root/out'"
run uninstall
check "uninstall again: nothing to do, exit 0" bash -c "[ $rc = 0 ] && grep -q 'Nothing to uninstall' '$root/out'"
reset
ACTIVE="datastore-pod.service"
export ACTIVE
run uninstall
check "uninstall: refused while a datastore pod runs, nothing removed" bash -c "[ $rc = 1 ] && grep -q 'Refused' '$root/out' && grep -q 'stop all' '$root/out' && diff -r '$rq' '$uh'"
reset
echo "# my edit" >>"$uh/kafka.container"
run uninstall
check "uninstall: a unit edited since the install stays, the others go" bash -c "[ $rc = 0 ] && [ \"\$(ls -A '$uh')\" = kafka.container ] && grep -q 'edited since the install' '$root/out'"
reset0
run uninstall
check "uninstall on a home where nothing was installed by this tool: exit 0, removes nothing" bash -c "[ $rc = 0 ] && grep -q 'Nothing to uninstall' '$root/out'"
reset0
mkdir -p "$uh"
echo mine >"$uh/postgresql.container"
run uninstall
check "uninstall: a same-named foreign unit without an install record is never removed" bash -c "[ -f '$uh/postgresql.container' ]"
reset
FAKE_UID=0 run uninstall
check "uninstall: refuses root" bash -c "[ $rc = 1 ] && diff -r '$rq' '$uh'"
reset0
run start
check "start before install: names the install command, starts nothing" bash -c "[ $rc = 1 ] && grep -q 'datastore install' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
reset0
run setup --pin postgresql=$pg_pin
check "pin before install: refused with the install command, nothing written" bash -c "[ $rc = 1 ] && grep -q 'datastore install' '$root/out' && [ ! -e '$uh' ]"
reset0
run setup --update --yes
check "update before install: refused with the install command, nothing pulled" bash -c "[ $rc = 1 ] && grep -q 'datastore install' '$root/out' && ! grep -q 'podman pull' '$LOG'"
reset
DATASTORE_UJUST=1 run setup --pin postgresql=$pg_pin --no
check "DATASTORE_UJUST=1: the messages name the ujust recipes" bash -c "grep -q 'ujust datastore-setup --unpin postgresql' '$root/out'"
reset
DATASTORE_UJUST=1 run start
check "DATASTORE_UJUST=1: the hint names ujust datastore-setup" bash -c "grep -q 'ujust datastore-setup first' '$root/out'"
# status against a newer bundle than the installed units
reset
mkdir -p "$root/b3"
sed 's/^\(kafka [^ ]*\):[^@]*@/\1:9.9.9@/' "$list" >"$root/b3/images.txt"
DATASTORE_IMAGES="$root/b3/images.txt" run setup --status
check "status: a bundle pin that differs from the installed unit is shown with the install command" bash -c "grep -q 'bundle .*:9.9.9@' '$root/out' && grep -q 'datastore install' '$root/out'"
reset0
run setup --status
check "status before install: says not installed" bash -c "[ $rc = 0 ] && grep -q 'not installed' '$root/out'"

# ---- the bundle's files: what the image carries and how it is built
check "bundle: bin/datastore, lib/render.sh and lib/datastore.sh exist, the two scripts are executable" bash -c "[ -x '$dsdir/bin/datastore' ] && [ -x '$dsdir/lib/render.sh' ] && [ -f '$dsdir/lib/datastore.sh' ]"
check "bundle: no bash syntax error in the scripts" bash -c "bash -n '$dsdir/bin/datastore' && bash -n '$dsdir/lib/render.sh' && bash -n '$dsdir/lib/datastore.sh'"
cf="$dsdir/Containerfile"
check "Containerfile: FROM scratch, carries images.txt, README, bin, lib and quadlets" bash -c "grep -qE '^FROM scratch\$' '$cf' && for p in images.txt README.md bin/ lib/ quadlets/; do grep -qE \"^COPY datastore-images/\$p \" '$cf' || exit 1; done"
check "Containerfile.dockerignore lets exactly those paths into the build context" bash -c "grep -qx '\\*' '$dsdir/Containerfile.dockerignore' && for p in images.txt README.md bin lib quadlets; do grep -qx \"!datastore-images/\$p\" '$dsdir/Containerfile.dockerignore' || exit 1; done"
check "image.env DATA_FILES names every file of the bundle, so the build compares each with the repository" bash -c "
  want=\$(cd '$dsdir' && ls bin/* lib/* quadlets/* | sed 's|^|datastore-images/|' | sort); have=\$(REPO_ROOT='$here' '$here/.github/scripts/images.sh' data-files datastore-images | cut -d: -f1 | grep -vE 'images.txt|README.md' | sort)
  [ \"\$want\" = \"\$have\" ]"
check "image.env DATA_CHECK names an executable script" bash -c "f=\$(REPO_ROOT='$here' '$here/.github/scripts/images.sh' data-check datastore-images); [ -n \"\$f\" ] && [ -x '$here'/\$f ]"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
