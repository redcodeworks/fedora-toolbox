# fedora-toolbox

This repo builds toolbox images only: [distrobox](https://distrobox.it)/container development environments, one per top-level directory. OS and bootc images (for example octarine-os) live in their own repos.

The first image is `fedora-toolbox/`, published as `ghcr.io/redcodeworks/fedora-toolbox`.

It is built `FROM ghcr.io/ublue-os/fedora-toolbox:latest` ([ublue-os/toolboxes](https://github.com/ublue-os/toolboxes)) and adds a build chain and the common `-devel` libraries (C/C++/Fortran/Clang, cmake, ninja, meson, OpenSSL, libpq, GLib, graphics and audio headers, ROCm tools), plus `uv`, `rustup` and `fish` from Fedora's repositories. The full list is [`fedora-toolbox/packages/dev.txt`](fedora-toolbox/packages/dev.txt). Official Fedora packages only, plus whatever the base already configures.

SDKMAN and nvm are not in the image: they install at runtime into the (shared) home.

## Images

Every top-level directory that contains a `Containerfile` is one image (and its build context); the image name is the directory name (`ghcr.io/redcodeworks/<directory>`), unless `<dir>/image.env` sets `IMAGE_NAME`. `just list` shows them. A directory holds `Containerfile`, `packages/dev.txt`, `build_files/build.sh` and `tests/smoke.sh`.

Add an image with `just new-image <name>`: it scaffolds a toolbox image (`FROM ghcr.io/ublue-os/fedora-toolbox:latest`, a package list, `build.sh`, a smoke-test skeleton) that passes `just lint`. Then edit `<name>/packages/dev.txt` and `<name>/tests/smoke.sh`, and check with `just build <name>` and `just smoke <name>`.

## How CI picks images

A `plan` job decides per run (no `paths:` filter, which would leave required checks pending): pull requests and pushes build the images whose directory changed; a change to a shared file (`.github/` except Renovate/Dependabot config, the root `Justfile`, `cosign.pub`) builds all; the weekly schedule builds all; a manual run builds all or one (`image` input); no changes means nothing to build and the required checks still pass. Each image is built, smoke-tested, published and signed by its own run of `build-image.yml`.

## Tags and branches

- Per image: `latest` and `latest-<YYYYMMDD>-<short sha>` (a dated tag to pin) are published from `main`.
- `testing` and `testing-<YYYYMMDD>-<short sha>`: published from the `testing` branch, for trying changes before they reach `main`.

`main` is protected and changes only by a merge-commit pull request from `testing` (`just release`, or `just release true` to wait for checks and merge); `require-testing-branch` enforces the source branch. Pushes to `main`, the weekly schedule (Sunday 06:00 UTC) and manual runs on `main` publish `latest`. Pull requests build and smoke-test without pushing or signing. A separate `sign` job signs every pushed digest with cosign and verifies it against `cosign.pub`; the private key is the `SIGNING_SECRET` secret of the GitHub environment `signing` (branches `main` and `testing`). A scheduled workflow prunes old `testing` builds of each image (newest 10 kept, never `latest*`); it only deletes when the repository variable `PRUNE_ENABLED` is `true`.

Renovate assumption: automerge of base-digest bumps only works if branch protection on `main` lets it through. Renovate's own branches fail `require-testing-branch`, so those digest PRs need a manual merge or a ruleset exception, and the required checks are `Build and push image`, `require-testing-branch` and `Sign and verify images` (aggregate jobs that pass when every planned image succeeded or nothing was planned). Renovate pins the `FROM` digest in every `*/Containerfile`.

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/fedora-toolbox:latest
```

## Use

With a shared home (distrobox's default):

```bash
distrobox create --name fedora-toolbox --image ghcr.io/redcodeworks/fedora-toolbox:latest
distrobox enter fedora-toolbox
```

To try a box from the `testing` image first:

```bash
distrobox create --name fedora-toolbox-testing --image ghcr.io/redcodeworks/fedora-toolbox:testing
```

On nox the host recipe `ujust dev-toolbox` (defined in `redcodeworks/ublue-os`) creates the box from this image. The image holds nothing user-specific, so the box works with the host's real home; SDKMAN and nvm are installed there by the recipe.

## Base image notes

The base is Fedora 44 with a moving `latest` tag, not rebuilt on a schedule, and Mesa from Terra. Package names are Fedora 44 names (Fedora 45 renames `libgit2-devel` to `libgit2_1.9-devel`), and `ffmpeg-free-devel` must stay out because libGLU cannot install with Terra's Mesa. See the comments in `fedora-toolbox/packages/dev.txt`.

## Develop

```bash
just list                    # the images
just build fedora-toolbox    # podman build, localhost/fedora-toolbox:latest
just smoke fedora-toolbox    # run fedora-toolbox/tests/smoke.sh inside it
just lint                    # scripts, image layouts, package lists, toolbox-only rule
just test                    # planning and scaffold tests
```

Add a package by adding one line to `fedora-toolbox/packages/dev.txt` (`@group` lines work too). A package that cannot be installed fails the build.

## Signing setup (one time)

```bash
COSIGN_PASSWORD="" cosign generate-key-pair   # writes cosign.key (never commit) and cosign.pub
```

Create the GitHub environment `signing` (branches `main` and `testing`), store the contents of `cosign.key` as the environment secret `SIGNING_SECRET`, commit `cosign.pub`, and enable GitHub Actions. After the first push to `main`, set the package `fedora-toolbox` to public so distrobox can pull it without logging in.

## License

Apache-2.0, see `LICENSE`.
