# CLAUDE.md

Guidance for Claude Code in this repo (`redcodeworks/fedora-toolbox`). `AGENTS.md` is Kevin's own file; never create or edit it.

## What this image is

A development toolbox container image, `ghcr.io/redcodeworks/fedora-toolbox`. It is NOT an OS image: no bootc, ostree, rpm-ostree, kernel, disk or ISO steps. The repo started from the Universal Blue `image-template`; the OS-image parts were removed.

The host (nox, an immutable Fedora Silverblue-based bootc image defined in `~/Repos/ublue-os`) consumes it through the recipe `ujust dev-toolbox`, which creates a distrobox from this image with a SHARED HOME (the box uses the host user's real home). Consequences:
- Nothing user-specific goes into the image: no `/home/<user>` content, no home paths, no dotfiles, no per-user config. `tests/smoke.sh` checks this.
- SDKMAN and nvm are installed at runtime into the shared home by the recipe. They are not part of the image.
- `uv` and `rustup` come from dnf (the `rustup` package; `rustup-init` or the toolchain download happens at runtime in the home).
- The recipe, the host and real `distrobox`/`podman` runs live outside this repo. Anything needing them goes to the hub as `Needs from hub:`.

## Base image (decided by Kevin; do not change)

`FROM ghcr.io/ublue-os/fedora-toolbox:latest` (github.com/ublue-os/toolboxes), chosen because it carries integrations the plain Fedora toolbox lacks. Do not switch to `registry.fedoraproject.org/fedora-toolbox`. Facts as of 2026-11-07 (from Kevin's earlier setup, unverified from this repo):
- Fedora 44; a moving `latest` tag only, no other tags; not rebuilt on a schedule.
- Mesa comes from Terra's `terra-mesa` repo (the base's own choice; add no other out-of-tree repos).
- Package names are Fedora 44 names. `libgit2-devel` becomes `libgit2_1.9-devel` on Fedora 45, so `packages/dev.txt` may need changing when the base moves.
- `ffmpeg-free-devel` must stay out: libGLU cannot install once Fedora's mesa is excluded in favour of Terra's.

## Layout

- `Containerfile`: base, then `build_files/build.sh` installs `packages/dev.txt`, cleans dnf caches, sets OCI labels.
- `packages/dev.txt`: one package or `@group` per line, `#` comments. Changes are one-line diffs.
- `build_files/build.sh`: reads the list and runs one `dnf5 install`. Any unavailable package fails the build (no `--skip-unavailable`, `strict=1`).
- `tests/smoke.sh`: runs inside the built image.
- `Justfile`: `just build`, `just smoke`, `just lint`, `just check`, `just fix`.
- `.github/workflows/build.yml`: CI. `.github/renovate.json5`, `.github/dependabot.yml`: updates.
- `image-template.env`: image name, org, description, default tag for the Justfile.

## Package policy

Official Fedora packages only, plus whatever the base already configures (Terra). No COPR, vendor repos or out-of-tree RPMs without Kevin's decision (put it under `Needs from hub:`). Packages already in the base are no-ops. `@group` entries: dnf5 accepts `@id` arguments to `dnf5 install` (mandatory and default members, not optional); the build script passes lines through unchanged, so the form is `@c-development`.

## Build and test

- `just build` builds locally with podman (tag `localhost/fedora-toolbox:latest`). `just smoke` runs `tests/smoke.sh` in it. `just lint` runs `bash -n` and shellcheck (if installed) on scripts and checks the package list. `just check` verifies Justfile formatting.
- Never run `distrobox` or `podman` against Kevin's real containers. A local build or smoke test creates only a throwaway image/container; if podman is blocked or there is no network (as in the agent sandbox), say plainly that nothing was built. A failed dnf resolution is exactly what the CI build exists to catch.

## Branch, CI and signing rules

- Branch flow (same as octarine-os in `~/Repos/ublue-os`): `testing` builds and publishes the `testing` image; `main` is protected, changes only by pull request from `testing` (merge commit, never squash or rebase), and publishes `latest`. `just release` opens the pull request from `testing` into `main`; `just release true` also waits for the required checks and merges it (needs `gh`). `.github/workflows/require-testing-branch.yml` fails any pull request into `main` that is not from the `testing` branch of this repository. Required checks on `main`: `Build and push image` (build job in `build.yml`) and `require-testing-branch`. Never push, open pull requests or merge unless Kevin asked.
- CI (`build.yml`), no path filter so every push builds: pushes to `testing` publish tags `testing` and `testing-<YYYYMMDD>-<short sha>`; pushes to `main`, the weekly schedule (exactly one cron entry, `0 6 * * 0`, Sunday 06:00 UTC, which runs on the default branch) and manual runs on `main` publish `latest` and `latest-<YYYYMMDD>-<short sha>`. Pull requests (into `main`) build and smoke-test only: no push, no signing. Both publish paths go through the separate `sign` job (`Sign and verify images`), which signs every distinct pushed digest and verifies each digest and tag against `cosign.pub`.
- Pruning: `.github/workflows/prune-testing.yml` with `.github/scripts/prune-testing.py` (copied from ublue-os, one image) runs Sundays 04:17 UTC. It keeps the newest 10 `testing` builds and deletes older ones with their cosign `.sig` versions; it never touches anything tagged `latest*` or any version with a non-`testing` tag, deletes untagged versions older than 7 days, and refuses to delete more than 60 versions per run. Scheduled runs only delete when the repository variable `PRUNE_ENABLED` is `true`, otherwise they are dry runs; a manual run defaults to dry run.
- Signing: public key `cosign.pub` is committed at the repo root. The private key is the secret `SIGNING_SECRET` stored in the GitHub environment `signing` (not at repo level, environment limited to `main` and `testing`); only the `sign` job uses that environment, so the build job never sees the key. `cosign.key` is gitignored and must never be read, printed or committed. Old bundle format (`--new-bundle-format=false --use-signing-config=false`).
- Base digest pinning: Renovate (`config:best-practices`) pins the `FROM` digest and opens update PRs; digest bumps of the base automerge. Actions are pinned by SHA and updated by Renovate and Dependabot.
- Commits: on `testing`, explicit paths only (never `git add -A`), message says why, trailer `Co-Authored-By` from the session reminder, wrapped in `~/.config/scripts/with-lock.sh repo-fedora-toolbox git commit ...`.

## Deliberately not in the image

SDKMAN, nvm, Node, Java (runtime installs into the shared home); anything in `/home`; Terra or other repos beyond the base's; `ffmpeg-free-devel`; any OS-image tooling (bootc, rpm-ostree, kernel, bootloader, ISO/disk builders).
