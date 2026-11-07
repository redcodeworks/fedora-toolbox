# fedora-toolbox

A Fedora development toolbox image for [distrobox](https://distrobox.it), published as `ghcr.io/redcodeworks/fedora-toolbox`.

It is built `FROM ghcr.io/ublue-os/fedora-toolbox:latest` ([ublue-os/toolboxes](https://github.com/ublue-os/toolboxes)) and adds a build chain and the common `-devel` libraries (C/C++/Fortran/Clang, cmake, ninja, meson, OpenSSL, libpq, GLib, graphics and audio headers, ROCm tools), plus `uv`, `rustup` and `fish` from Fedora's repositories. The full list is [`packages/dev.txt`](packages/dev.txt). Official Fedora packages only, plus whatever the base already configures.

SDKMAN and nvm are not in the image: they install at runtime into the (shared) home.

## Tags

- `latest`: the newest build.
- `latest-<YYYYMMDD>-<short sha>`: a dated tag to pin.

Only `main` publishes: pushes to `main`, once a week (Sunday 06:00 UTC) and manual runs on `main`. Builds on `testing` and on pull requests build and smoke-test without pushing or signing. A separate `sign` job signs every pushed digest with cosign and verifies it against the public key `cosign.pub`. The private key lives in the GitHub environment `signing` (secret `SIGNING_SECRET`), which allows `main` and, on purpose for a later change, `testing`.

Pull requests into `main` must come from `testing` (`require-testing-branch`). Assumption for Renovate: automerge of base-digest bumps only works if branch protection on `main` allows it and the required checks are `Build and push image` and `require-testing-branch`; the `require-testing-branch` check fails for Renovate's own branches, so those digest PRs are expected to need a manual merge or a ruleset exception unless Kevin arranges otherwise.

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/fedora-toolbox:latest
```

## Use

With a shared home (distrobox's default):

```bash
distrobox create --name fedora-toolbox --image ghcr.io/redcodeworks/fedora-toolbox:latest
distrobox enter fedora-toolbox
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
