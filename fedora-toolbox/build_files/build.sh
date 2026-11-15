#!/usr/bin/bash
# Install the shared developer package list into the image. Called from the Containerfile with the
# build context mounted at /ctx. The list lives in dev-packages/ and the installer in package-installer/ (both
# published as ghcr.io/redcodeworks/dev-packages for other images); the installer resolves alternatives, runs one
# strict dnf5 install (any unavailable package fails the build, no --skip-unavailable) and removes
# the build residue.
set -euo pipefail

exec bash /ctx/dev-packages/install.sh /ctx/dev-packages/dev.txt
