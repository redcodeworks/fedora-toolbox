#!/usr/bin/bash
# Install packages/required-fedora.txt, then the pinned downloads of downloads.lock (checksum verified). Called from the
# Containerfile with the build context mounted at /ctx. Fails loudly on anything unavailable or any bad checksum.
set -euo pipefail

mapfile -t pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' /ctx/packages/required-fedora.txt)
[ "${#pkgs[@]}" -gt 0 ] || { echo "build.sh: no packages in packages/required-fedora.txt" >&2; exit 1; }
echo "Installing ${#pkgs[@]} packages"
# strict: a missing package aborts; weak dependencies off keeps the image small
dnf5 -y install --setopt=strict=1 --setopt=install_weak_deps=False "${pkgs[@]}"

work=$(mktemp -d)
while IFS='|' read -r name version url algo sum; do
    case "${name}" in '' | '#'*) continue ;; esac
    case "${algo}" in sha256 | sha512) ;; *) echo "build.sh: ${name}: unsupported algorithm '${algo}'" >&2; exit 1 ;; esac
    echo "Downloading ${name} ${version}"
    curl -fsSL --retry 3 --retry-delay 5 -o "${work}/${name}.archive" "${url}"
    echo "${sum}  ${work}/${name}.archive" | "${algo}sum" -c - || { echo "build.sh: ${name}: checksum mismatch, refusing to install" >&2; exit 1; }
    mkdir "${work}/${name}"
    tar -xzf "${work}/${name}.archive" -C "${work}/${name}"
    case "${name}" in
        seaweedfs)
            install -m 0755 "${work}/${name}/weed" /usr/local/bin/weed
            ;;
        kafka)
            # /opt/kafka is the directory the apache/kafka container image uses too
            mkdir -p /opt/kafka
            cp -a "${work}/${name}/kafka_2.13-${version}/." /opt/kafka/
            ;;
        *) echo "build.sh: no install rule for '${name}'" >&2; exit 1 ;;
    esac
done < /ctx/downloads.lock
# Kafka's logs belong to the user's data directory (LOG_DIR in the unit), not to /opt/kafka
rm -rf /opt/kafka/logs "${work}"

dnf5 clean all
# Build residue that must not ship: dnf logs (mirror URLs), root's leftovers
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* \
    /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts 2>/dev/null || true
