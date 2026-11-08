# fedora-toolbox

A Fedora development toolbox image for [distrobox](https://distrobox.it), published as `ghcr.io/redcodeworks/fedora-toolbox`.

It is built `FROM ghcr.io/ublue-os/fedora-toolbox:latest` ([ublue-os/toolboxes](https://github.com/ublue-os/toolboxes)) and adds a build chain and the common `-devel` libraries (C/C++/Fortran/Clang, cmake, ninja, meson, OpenSSL, libpq, GLib, graphics and audio headers, ROCm tools), plus `uv`, `rustup` and `fish` from Fedora's repositories. The full list is [`packages/dev.txt`](packages/dev.txt). Official Fedora packages only, plus whatever the base already configures.

SDKMAN and nvm are not in the image: they install at runtime into the (shared) home.

## Tags and branches

- `latest` and `latest-<YYYYMMDD>-<short sha>` (a dated tag to pin): published from `main`.
- `testing` and `testing-<YYYYMMDD>-<short sha>`: published from the `testing` branch, for trying changes before they reach `main`.

`main` is protected and changes only by a merge-commit pull request from `testing` (`just release`, or `just release true` to wait for checks and merge); `require-testing-branch` enforces the source branch. Pushes to `main`, the weekly schedule (Sunday 06:00 UTC) and manual runs on `main` publish `latest`. Pull requests build and smoke-test without pushing or signing. A separate `sign` job signs every pushed digest with cosign and verifies it against `cosign.pub`; the private key is the `SIGNING_SECRET` secret of the GitHub environment `signing` (branches `main` and `testing`). A scheduled workflow prunes old `testing` builds (newest 10 kept, never `latest*`); it only deletes when the repository variable `PRUNE_ENABLED` is `true`.

Renovate assumption: automerge of base-digest bumps only works if branch protection on `main` lets it through. Renovate's own branches fail `require-testing-branch`, so those digest PRs need a manual merge or a ruleset exception, and the required checks are `Build and push image`, `require-testing-branch` and `Sign and verify images`.

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

The base is Fedora 44 with a moving `latest` tag, not rebuilt on a schedule, and Mesa from Terra. Package names are Fedora 44 names (Fedora 45 renames `libgit2-devel` to `libgit2_1.9-devel`), and `ffmpeg-free-devel` must stay out because libGLU cannot install with Terra's Mesa. See the comments in `packages/dev.txt`.

## Develop

```bash
just build   # podman build, localhost/fedora-toolbox:latest
just smoke   # run tests/smoke.sh inside it
just lint    # shell syntax, shellcheck if installed, package list sanity
```

Add a package by adding one line to `packages/dev.txt` (`@group` lines work too). A package that cannot be installed fails the build.

## Signing setup (one time)

```bash
COSIGN_PASSWORD="" cosign generate-key-pair   # writes cosign.key (never commit) and cosign.pub
```

Create the GitHub environment `signing` (branches `main` and `testing`), store the contents of `cosign.key` as the environment secret `SIGNING_SECRET`, commit `cosign.pub`, and enable GitHub Actions. After the first push to `main`, set the package `fedora-toolbox` to public so distrobox can pull it without logging in.

## License

Apache-2.0, see `LICENSE`.
