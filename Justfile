default_tag := "latest"

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

# List the images (every top-level directory with a Containerfile): directory, name, description
[group('Image')]
list:
    @.github/scripts/images.sh list

# Build an image locally with podman (by directory or image name)
[group('Image')]
build image tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r dir name < <(.github/scripts/images.sh resolve "{{ image }}")
    podman build --pull=newer -f "${dir}/Containerfile" -t "localhost/${name}:{{ tag }}" "${dir}"

# Run <image>/tests/smoke.sh inside the locally built image
[group('Image')]
smoke image tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r dir name < <(.github/scripts/images.sh resolve "{{ image }}")
    podman run --rm -v "{{ justfile_directory() }}/${dir}/tests/smoke.sh:/smoke.sh:ro" "localhost/${name}:{{ tag }}" bash /smoke.sh

# Lint scripts, image layouts and package lists, and enforce "toolbox images only"
[group('Image')]
lint:
    @.github/scripts/lint.sh

# Scaffold a new toolbox image directory from the minimal template
[group('Image')]
new-image name:
    @.github/scripts/new-image.sh "{{ name }}"

# Run the planning and scaffold tests
[group('Image')]
test:
    tests/plan-images.sh
    tests/new-image.sh

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
