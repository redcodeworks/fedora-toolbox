#!/usr/bin/env bash
# Static checks of the dna-toolbox server stack (no container runtime, no host access): the shipped
# Quadlet and compose files render, images are pinned, ports are offset and local, no secrets in files.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DNA_STACK_ROOT="${here}/dna-toolbox/stack" "${here}/dna-toolbox/stack/bin/dna-stack" check
echo "ok   dna-stack static checks"
