#!/usr/bin/bash
# Static smoke test, run INSIDE the built image (no systemd, no services):
#   podman run --rm -v ./tests/smoke.sh:/smoke.sh:ro <image> bash /smoke.sh
# The runtime test (the real box with its own systemd) is tests/smoke-host.sh, which `just smoke` runs on the host.
set -euo pipefail

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

run() {
    local out
    out=$("$@" 2>&1) || fail "'$*' failed: $out"
    echo "ok: $* -> $(head -n1 <<<"$out")"
}

run postgres --version
postgres --version | grep -q ' 17\.' || fail "PostgreSQL is not major 17"
run initdb --version
run pg_dumpall --version
run psql --version
run valkey-server --version
run valkey-cli --version
run java -version
java -version 2>&1 | grep -q '"25\.' || fail "java is not 25"
run weed version
run /opt/kafka/bin/kafka-topics.sh --version
/opt/kafka/bin/kafka-topics.sh --version | grep -q '^4\.3\.2' || fail "Kafka is not 4.3.2"
run systemctl --version
run sudo --version
run datastore --help

# Templates are rendered at setup time with the box user's name: nothing may be hard-coded
for f in /usr/share/datastore/units/datastore-{postgres,valkey,seaweedfs,kafka}.service.in; do
    [ -f "$f" ] || fail "missing $f"
    grep -q '^User=@USER@$' "$f" || fail "$f does not run as @USER@"
done
out=$(mktemp -d)
HOME=/nonexistent datastore render "$out" >/dev/null
grep -rq '@[A-Z]*@' "$out" && fail "placeholders left after render"
echo "ok: units render without placeholders"

# Hygiene: no dnf logs, no /root residue, nothing user-specific
ls /var/log/dnf5.log* >/dev/null 2>&1 && fail "dnf logs left in the image"
for p in /root/.ssh /root/.viminfo /root/.cache; do [ ! -e "$p" ] || fail "$p left in the image"; done
if [ -d /home ] && [ -n "$(find /home -mindepth 1 -maxdepth 2 2>/dev/null | head -n1)" ]; then fail "/home is not empty"; fi
extra=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | tr '\n' ' ')
[ -z "$extra" ] || fail "image defines regular users: $extra"
echo "ok: no residue, no user-specific content"

echo "SMOKE PASS"
