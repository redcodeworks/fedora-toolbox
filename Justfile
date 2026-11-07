set dotenv-filename := "image-template.env"
set dotenv-load

export image_name := env_var("IMAGE_NAME")
export default_tag := env_var("DEFAULT_TAG")

[private]
default:
    @just --list

# Check Justfile formatting
[group('Just')]
check:
    just --unstable --fmt --check -f Justfile

# Fix Justfile formatting
[group('Just')]
fix:
    just --unstable --fmt -f Justfile

# Build the image locally with podman
[group('Image')]
build $target_image=image_name $tag=default_tag:
    podman build --pull=newer -f Containerfile -t localhost/{{ target_image }}:{{ tag }} .

# Run tests/smoke.sh inside the locally built image
[group('Image')]
smoke $target_image=image_name $tag=default_tag:
    podman run --rm -v "{{ justfile_directory() }}/tests/smoke.sh:/smoke.sh:ro" localhost/{{ target_image }}:{{ tag }} bash /smoke.sh

# Lint shell scripts and the package list
[group('Image')]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    bash -n build_files/build.sh tests/smoke.sh
    if command -v shellcheck >/dev/null; then
        shellcheck build_files/build.sh tests/smoke.sh
    else
        echo "shellcheck not installed, skipping"
    fi
    entries() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' packages/dev.txt; }
    # every non-comment line must be one token: a package name or @group
    bad=$(entries | grep -nE '[[:space:]]' || true)
    if [ -n "$bad" ]; then echo "packages/dev.txt: more than one token per line:"; echo "$bad"; exit 1; fi
    dups=$(entries | sort | uniq -d)
    if [ -n "$dups" ]; then echo "packages/dev.txt: duplicates:"; echo "$dups"; exit 1; fi
    echo "lint ok"
