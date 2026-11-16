# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are used by bin/datastore, which sources this file
# Shared helpers of bin/datastore. Sourced, never run. Rootless only: nothing here needs privileges, and the commands refuse root.
# The bundle root (DS_ROOT: the directory with images.txt, quadlets/ and lib/) is set by bin/datastore. Paths can be moved with
# DATASTORE_* variables for the tests.

DS_USER_DIR=${DATASTORE_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}
DS_STATE_DIR=${DATASTORE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/datastore}
DS_RECORD="${DS_STATE_DIR}/installed"
DS_SERVICES="postgresql valkey seaweedfs kafka"
DS_VOLUMES="postgresql-data valkey-data seaweed-data kafka-data"
DS_SECRETS_DATASTORE="postgresql-password valkey-password seaweedfs-s3-config"

# How the messages name the commands: DATASTORE_UJUST=1 (the ujust recipes set it) prints `ujust datastore ...` and
# `ujust datastore-setup ...`, otherwise `datastore ...` and `datastore setup ...`
if [[ -n "${DATASTORE_UJUST:-}" ]]; then DS_CMD="ujust datastore"; DS_SETUP="ujust datastore-setup"; else DS_CMD="datastore"; DS_SETUP="datastore setup"; fi

ds_known_service() { case " ${DS_SERVICES} " in *" $1 "*) return 0 ;; esac; return 1; }
# the container name and the systemd unit of a service, and the pod unit it belongs to
ds_container() { case "$1" in postgresql) echo pgsql ;; *) echo "$1" ;; esac; }
ds_unit() { echo "$1.service"; }
ds_pod_unit() { case "$1" in kafka) echo kafka-pod.service ;; *) echo datastore-pod.service ;; esac; }
ds_dropin() { echo "${DS_USER_DIR}/$1.container.d/10-image.conf"; }

# ds_confirm <question> <y|n>: asks on a terminal (the second argument is the default); without a terminal the answer is no
ds_confirm() {
    local a
    [[ -t 0 ]] || return 1
    if [[ "${2:-n}" = y ]]; then read -r -p "$1 [Y/n] " a; case "${a:-y}" in y | Y | yes) return 0 ;; esac; else read -r -p "$1 [y/N] " a; case "${a:-n}" in y | Y | yes) return 0 ;; esac; fi
    return 1
}

# ds_images_file: images.txt of the bundle (DATASTORE_IMAGES overrides it, for the tests)
# ds_bundle_image <service>: the reference in that file (tag and digest included)
ds_images_file() { echo "${DATASTORE_IMAGES:-${DS_ROOT}/images.txt}"; }
ds_bundle_image() { awk -v n="$1" '$1 == n { print $2; exit }' "$(ds_images_file)"; }
# ds_installed: success when the units are installed (the pod file is the marker)
ds_installed() { [[ -f "${DS_USER_DIR}/datastore.pod" ]]; }
# ds_shipped_image <service>: the Image= of the installed Quadlet (tag and digest included), empty when not installed
ds_shipped_image() { sed -n 's/^Image=//p' "${DS_USER_DIR}/$1.container" 2> /dev/null | head -n1; }
# ds_override_image <service>: the Image= of the user's drop-in, empty when there is none
ds_override_image() { local f; f=$(ds_dropin "$1"); if [[ -f "${f}" ]]; then sed -n 's/^Image=//p' "${f}" | tail -n1; fi; }
ds_effective_image() { local o; o=$(ds_override_image "$1"); echo "${o:-$(ds_shipped_image "$1")}"; }
# the registry path without tag and digest, and the major version of the tag (17.12-alpine -> 17)
ds_image_path() { local i=${1%%@*}; echo "${i%:*}"; }
ds_image_tag() { local i=${1%%@*}; echo "${i##*:}"; }
ds_image_major() { local t; t=$(ds_image_tag "$1"); echo "${t%%.*}"; }

ds_secret_exists() { podman secret inspect "$1" > /dev/null 2>&1; }
ds_missing_secrets() { local s; for s in ${DS_SECRETS_DATASTORE}; do ds_secret_exists "${s}" || echo "${s}"; done; }

# ds_pg_data_major: the PG_VERSION of the data volume (read in podman's user namespace, where the files of the container user are
# readable); empty when the volume does not exist or holds no cluster yet
ds_pg_data_major() {
    local mp
    podman volume exists postgresql-data 2> /dev/null || return 0
    mp=$(podman volume inspect postgresql-data --format '{{.Mountpoint}}' 2> /dev/null) || return 0
    [[ -n "${mp}" ]] || return 0
    podman unshare cat "${mp}/pgdata/PG_VERSION" 2> /dev/null | head -n1 | tr -d '[:space:]'
}
# ds_pg_guard: refuse (1) when the data's major differs from the image's major, with the dump and restore message
ds_pg_guard() {
    local data image_major
    data=$(ds_pg_data_major)
    [[ -n "${data}" ]] || return 0
    image_major=$(ds_image_major "$(ds_effective_image postgresql)")
    if [[ "${data%%.*}" != "${image_major}" ]]; then
        echo "Refusing to start PostgreSQL: the data volume is PostgreSQL ${data%%.*}, the image is ${image_major}." >&2
        echo "A major version needs a dump and restore (pg_dumpall with the old version, then restore into a new volume) or pg_upgrade;" >&2
        echo "starting the new server on old data would fail. Pin the old tag instead: ${DS_SETUP} --pin postgresql=<${data%%.*}.x tag>" >&2
        return 1
    fi
    return 0
}

# ds_validate <dir>: checks a rendered Quadlet directory before anything is placed: no [Install] section (nothing starts by itself),
# the unit, pod, network and volume names that existing users' data and secrets depend on, and one Image= per container that is the
# reference of images.txt. Prints one message per problem, returns 1 when there is any.
ds_validate() {
    local d=$1 bad=0 s v f
    if grep -rqE '^\[Install' "${d}"; then echo "validate: a rendered unit has an [Install] section (nothing may start by itself)" >&2; bad=1; fi
    for s in ${DS_SERVICES}; do
        f="${d}/${s}.container"
        if [[ ! -f "${f}" ]]; then echo "validate: ${s}.container is missing" >&2; bad=1; continue; fi
        [[ "$(grep -c '^Image=' "${f}")" = 1 && "$(sed -n 's/^Image=//p' "${f}")" = "$(ds_bundle_image "${s}")" ]] || { echo "validate: ${s}.container: Image= is not the reference of images.txt" >&2; bad=1; }
        grep -qx "ContainerName=$(ds_container "${s}")" "${f}" || { echo "validate: ${s}.container: ContainerName= changed (expected $(ds_container "${s}"))" >&2; bad=1; }
    done
    for v in ${DS_VOLUMES}; do
        grep -qx "VolumeName=${v}" "${d}/${v}.volume" 2> /dev/null || { echo "validate: ${v}.volume with VolumeName=${v} is missing (existing data lives in that volume)" >&2; bad=1; }
    done
    grep -qx 'PodName=datastore' "${d}/datastore.pod" 2> /dev/null || { echo "validate: datastore.pod with PodName=datastore is missing" >&2; bad=1; }
    grep -qx 'PodName=kafka' "${d}/kafka.pod" 2> /dev/null || { echo "validate: kafka.pod with PodName=kafka is missing" >&2; bad=1; }
    grep -qx 'NetworkName=lakehouse' "${d}/lakehouse.network" 2> /dev/null || { echo "validate: lakehouse.network with NetworkName=lakehouse is missing" >&2; bad=1; }
    return "${bad}"
}
