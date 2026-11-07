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

# Open the release pull request from testing into main. Pass true to also wait for the required checks and merge it
[group('Release')]
release $merge="false":
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch -q origin
    branch=$(git rev-parse --abbrev-ref HEAD)
    [[ "$branch" == "testing" ]] || { echo "Switch to the testing branch first (you are on '$branch')"; exit 1; }
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit or stash your changes first"; exit 1; }
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/testing)" ]] || { echo "testing is not in sync with origin/testing: push (or pull) first"; exit 1; }
    [[ "$(git rev-list --count origin/main..origin/testing)" -gt 0 ]] || { echo "testing has nothing that main does not already have"; exit 0; }

    url=$(gh pr list --base main --head testing --state open --json url --jq '.[0].url // empty')
    if [[ -z "$url" ]]; then
        url=$(gh pr create --base main --head testing \
            --title "Release $(date +%Y-%m-%d)" \
            --body "$(git log --format='- %s' origin/main..origin/testing)")
    fi
    echo "$url"

    if [[ "$merge" == "true" ]]; then
        echo "Waiting for the required checks (the build can take a while)..."
        gh pr checks "$url" --watch --required
        gh pr merge "$url" --merge
        echo "Merged. The latest build is running: gh run list --branch main --limit 1"
    else
        echo "When the checks pass, merge it with: just release true   (or: gh pr merge --merge)"
    fi
