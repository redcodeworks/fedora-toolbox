# fedora-toolbox

A Fedora development toolbox image for [distrobox](https://distrobox.it), published as `ghcr.io/redcodeworks/fedora-toolbox`.

It is built `FROM ghcr.io/ublue-os/fedora-toolbox:latest` ([ublue-os/toolboxes](https://github.com/ublue-os/toolboxes)) and adds a build chain and the common `-devel` libraries (C/C++/Fortran/Clang, cmake, ninja, meson, OpenSSL, libpq, GLib, graphics and audio headers, ROCm tools), plus `uv`, `rustup` and `fish` from Fedora's repositories. The full list is [`packages/dev.txt`](packages/dev.txt). Official Fedora packages only, plus whatever the base already configures.

SDKMAN and nvm are not in the image: they install at runtime into the (shared) home.

## Tags

- `latest`: the newest build.
- `latest-<YYYYMMDD>-<short sha>`: a dated tag to pin.

Builds run on every push to `main`, once a week (Sunday 06:00 UTC) and on demand; pull requests build and test without pushing or signing. Images are signed with cosign; the public key is `cosign.pub`.

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
gh secret set SIGNING_SECRET < cosign.key
git add cosign.pub
```

Then enable GitHub Actions for the repository and, after the first push, set the package `fedora-toolbox` to public in the GitHub package settings so distrobox can pull it without logging in.

## License

Apache-2.0, see `LICENSE`.
