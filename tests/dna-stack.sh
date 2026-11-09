#!/usr/bin/env bash
# Static checks of the dna-toolbox server stack (no container runtime, no host access): the shipped
# Quadlet and compose files render, images are pinned, ports are offset and local, no secrets in files.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DNA_STACK_ROOT="${here}/dna-toolbox/stack" "${here}/dna-toolbox/stack/bin/dna-stack" check
echo "ok   dna-stack static checks"

# dna-toolbox: versions.env parses, the Java package matches DNA_JAVA_VERSION, downloads are pinned
tb="${here}/dna-toolbox"
# shellcheck source=/dev/null
( set -a; . "${tb}/versions.env"; set +a
  grep -qx "java-${DNA_JAVA_VERSION}-openjdk" "${tb}/packages/optional.txt" ) \
    || { echo "FAIL optional.txt lacks java-<DNA_JAVA_VERSION>-openjdk" >&2; exit 1; }
while IFS='|' read -r name _ url sha _; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    [[ "${url}" == https://* && "${sha}" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL downloads.lock: ${name} is not pinned by https URL and sha256" >&2; exit 1; }
done < "${tb}/downloads.lock"
echo "ok   dna-toolbox versions.env, java package and download pins"
