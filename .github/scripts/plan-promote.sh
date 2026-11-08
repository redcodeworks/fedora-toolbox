#!/usr/bin/env bash
# Add the promote-or-build decision to every entry of the planned matrix.
#
#   plan-promote.sh '<matrix json>' <event> <ref>
#
# Each entry {"image":..,"dir":..} gains "mode" ("promote" or "build"), "source" (short sha of the
# tested commit, empty for build) and "reason". Decisions come from promote-decision.sh, per image.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
matrix="${1:?matrix}"
event="${2:?event}"
ref="${3:?ref}"

mapfile -t entries < <(python3 -I -c 'import json,sys
for e in json.loads(sys.argv[1])["include"]: print(e["image"], e["dir"])' "${matrix}")

lines=""
for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    read -r image dir <<<"${entry}"
    decision=$("${here}/promote-decision.sh" "${event}" "${ref}" "${dir}" "${image}")
    lines+="${image} ${dir} ${decision}"$'\n'
done

python3 -I -c 'import json,sys
out=[]
for l in sys.stdin.read().splitlines():
    if not l.strip(): continue
    image,d,mode,rest=(l.split(" ",3)+[""])[:4]
    out.append({"image":image,"dir":d,"mode":mode,"source":rest if mode=="promote" else "","reason":rest if mode=="build" else ""})
print(json.dumps({"include":out},separators=(",",":")))' <<<"${lines}"
