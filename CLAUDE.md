# CLAUDE.md

Guidance for Claude Code in this repo (`redcodeworks/fedora-toolbox`). `AGENTS.md` is Kevin's own file; never create or edit it.

## What this repo is

This repo builds toolbox images only: distrobox/container development environments, each one a top-level directory. octarine-os and any other OS or bootc image live in their own repos and never move here; nothing from them (build files, signature policy, recipes, image names) belongs here. `just new-image` and `just lint` enforce this (a toolbox base in `FROM`, no bootc/ostree/kernel/disk/ISO parts).

The first image is `fedora-toolbox/`, published as `ghcr.io/redcodeworks/fedora-toolbox` (that path is fixed: the host recipe depends on it). It is NOT an OS image: no bootc, ostree, rpm-ostree, kernel, disk or ISO steps. The repo started from the Universal Blue `image-template`; the OS-image parts were removed.

The host (nox, an immutable Fedora Silverblue-based bootc image defined in `~/Repos/ublue-os`) consumes it through the recipe `ujust dev-toolbox`, which creates a distrobox from this image with a SHARED HOME (the box uses the host user's real home). Consequences:
- Nothing user-specific goes into the image: no `/home/<user>` content, no home paths, no dotfiles, no per-user config. `tests/smoke.sh` checks this.
- SDKMAN and nvm are installed at runtime into the shared home by the recipe. They are not part of the image.
- `uv` and `rustup` come from dnf (the `rustup` package; `rustup-init` or the toolchain download happens at runtime in the home).
- The recipe, the host and real `distrobox`/`podman` runs live outside this repo. Anything needing them goes to the hub as `Needs from hub:`.

## Base image (decided by Kevin; do not change)

`FROM ghcr.io/ublue-os/fedora-toolbox:latest` (github.com/ublue-os/toolboxes), chosen because it carries integrations the plain Fedora toolbox lacks. Do not switch to `registry.fedoraproject.org/fedora-toolbox`. Facts as of 2026-11-07 (from Kevin's earlier setup, unverified from this repo):
- Fedora 44; a moving `latest` tag only, no other tags; not rebuilt on a schedule.
- Mesa comes from Terra's `terra-mesa` repo (the base's own choice; add no other out-of-tree repos).
- Package names are Fedora 44 names. `libgit2-devel` becomes `libgit2_1.9-devel` on Fedora 45, so `fedora-toolbox/packages/dev.txt` may need changing when the base moves.
- `ffmpeg-free-devel` must stay out: libGLU cannot install once Fedora's mesa is excluded in favour of Terra's.

## Layout (multi-image)

- Every top-level directory that contains a `Containerfile` is one image and its own build context. The image name is the directory name, unless `<dir>/image.env` sets `IMAGE_NAME` (and `IMAGE_DESC`). Directories without a `Containerfile` (`.github`, `tests`, ...) are not images.
- Per image: `<image>/Containerfile` (base, runs `build_files/build.sh`, OCI labels), `<image>/packages/dev.txt` (one package or `@group` per line, `#` comments, one-line diffs), `<image>/build_files/build.sh` (one strict `dnf5 install`; any unavailable package fails the build, no `--skip-unavailable`), `<image>/tests/smoke.sh` (runs inside the built image), optional `<image>/image.env`.
- Shared, at the root: `Justfile`, `README.md`, `CLAUDE.md`, `cosign.pub`, `.github/` (workflows, `.github/scripts/{images,plan-images,lint,new-image}.sh`, `prune-testing.py`, Renovate and Dependabot config), `tests/` (`plan-images.sh`, `new-image.sh`: tests of the shared scripts).
- `fedora-toolbox/` contents: build chain (gcc, g++, gfortran, clang, make, cmake, ninja, meson, gdb, valgrind and friends), common `-devel` libraries (OpenSSL, libpq, GLib, imaging, audio, graphics headers), hardware and ROCm tools, plus `uv`, `rustup` (ships `rustup-init`; `rustup` appears on first run in the home) and `fish` from Fedora. Full list: `fedora-toolbox/packages/dev.txt`.
- Recipes: `just list` (images), `just build <image>`, `just smoke <image>` (by directory or name), `just lint`, `just check` (Justfile format), `just test` (planning and scaffold tests), `just new-image <name>`, `just release`.
- Add an image: `just new-image <name>` scaffolds `<name>/` (FROM `ghcr.io/ublue-os/fedora-toolbox:latest`, a one-line package list, `build.sh`, a smoke skeleton) and passes `just lint`; edit the list and the smoke test. The name is lowercase letters, digits and dashes and is also the published image name `ghcr.io/redcodeworks/<name>`.

## Image hygiene

The end of each `build.sh` deletes build residue: `/var/log/dnf5.log*` (it contains mirror URLs), `/root/.ssh`, `/root/.viminfo`, `/root/.cache`, `/root/.local/share/wget`, plus the dnf caches. The Containerfile sets its OCI labels explicitly so nothing from the base is republished: `maintainer` (`redcodeworks/fedora-toolbox`, no email), `authors`, `vendor`, `url`, `documentation`, `source`, and `version`, `revision`, `created` from build args (`IMAGE_VERSION` = the dated tag, `IMAGE_REVISION` = the commit sha, `IMAGE_CREATED` = UTC time) that `build-image.yml` passes; local builds get `dev`/`unknown`. The workflow step "Check image labels" fails on any email address in a label or a wrong revision; `tests/smoke.sh` fails on dnf logs or `/root` residue. `just new-image` scaffolds the same cleanup.

## Package policy

Official Fedora packages only, plus whatever the base already configures (Terra). No COPR, vendor repos or out-of-tree RPMs without Kevin's decision (put it under `Needs from hub:`). Packages already in the base are no-ops. `@group` entries: dnf5 accepts `@id` arguments to `dnf5 install` (mandatory and default members, not optional); the build script passes lines through unchanged, so the form is `@c-development`.

## Build and test

- `just build fedora-toolbox` builds locally with podman (tag `localhost/fedora-toolbox:latest`, context `fedora-toolbox/`). `just smoke fedora-toolbox` runs `fedora-toolbox/tests/smoke.sh` in it. `just lint` runs `bash -n` and shellcheck (if installed) on all scripts, checks every image directory's layout and package list, unique image names and the toolbox-only rule. `just check` verifies Justfile formatting. `just test` runs `tests/plan-images.sh` and `tests/new-image.sh`.
- Never run `distrobox` or `podman` against Kevin's real containers. A local build or smoke test creates only a throwaway image/container; if podman is blocked or there is no network (as in the agent sandbox), say plainly that nothing was built. A failed dnf resolution is exactly what the CI build exists to catch.

## Branch, CI and signing rules

- Branch flow (same as octarine-os in `~/Repos/ublue-os`): `testing` builds and publishes the `testing` image; `main` is protected, changes only by pull request from `testing` (merge commit, never squash or rebase), and publishes `latest`. `just release` opens the pull request from `testing` into `main`; `just release true` also waits for the required checks and merges it (needs `gh`). `.github/workflows/require-testing-branch.yml` fails any pull request into `main` that is not from the `testing` branch of this repository. Required checks on `main` (as on octarine-os, applied 2026-11-07): `Build and push image`, `require-testing-branch` and `Sign and verify images`; pull request required (0 approvals), admins enforced, merge commits only. Never push, open pull requests or merge unless Kevin asked.
- CI picks images per run (`.github/workflows/build.yml`, no workflow-level `paths:` filter, which would leave required checks pending forever). The `plan` job runs `just check`, `just lint`, the two test scripts and `.github/scripts/plan-images.sh`, which prints the matrix: pull requests and pushes build the images whose directory has changed files in the commit range (PR base to head, `github.event.before` to `github.sha`); a change to a shared file (anything under `.github/` except `renovate.json5` and `dependabot.yml`, the root `Justfile`, `cosign.pub`) builds all images; an all-zero or unknown before-SHA builds all; the weekly schedule (exactly one cron entry, `0 6 * * 0`, Sunday 06:00 UTC, runs on the default branch) builds all; `workflow_dispatch` builds all or the one named in its optional `image` input; nothing changed gives an empty matrix. Each planned image runs the reusable `build-image.yml` (podman build with the image directory as context, `<image>/tests/smoke.sh`, publish, then the separate `sign` job; concurrency per image).
- Tags per image (`ghcr.io/redcodeworks/<name>`): pushes to `testing` publish `testing` and `testing-<YYYYMMDD>-<short sha>`; pushes to `main`, the weekly schedule and manual runs on `main` publish `latest` and `latest-<YYYYMMDD>-<short sha>`. Pull requests build and smoke-test only: no push, no signing. The `sign` job (environment `signing`) signs every distinct pushed digest and verifies each digest and tag against `cosign.pub`.
- Required check names (unchanged by the multi-image layout): the aggregate jobs `Build and push image` and `Sign and verify images` in `build.yml` (each passes when every planned image succeeded or the plan was empty; signing runs inside the per-image workflow, so a failure anywhere fails both) and `require-testing-branch`. Per-image jobs are shown as `images (<name>) / Build image` and `images (<name>) / Sign and verify image` and are not required.
- Pruning: `.github/workflows/prune-testing.yml` with `.github/scripts/prune-testing.py` runs Sundays 04:17 UTC once per image (a matrix over the image directories, names by the same rules). For each image it keeps the newest 10 `testing` builds and deletes older ones with their cosign `.sig` versions; it never touches anything tagged `latest*` or any version with a non-`testing` tag, deletes untagged versions older than 7 days, and refuses to delete more than 60 versions per run. Scheduled runs only delete when the repository variable `PRUNE_ENABLED` is `true`, otherwise they are dry runs; a manual run defaults to dry run.
- Signing: public key `cosign.pub` is committed at the repo root. The private key is the secret `SIGNING_SECRET` stored in the GitHub environment `signing` (not at repo level, environment limited to `main` and `testing`); only the `sign` job uses that environment, so the build job never sees the key. `cosign.key` is gitignored and must never be read, printed or committed. Old bundle format (`--new-bundle-format=false --use-signing-config=false`). One-time setup (done 2026-11-07): `COSIGN_PASSWORD="" cosign generate-key-pair` (unprotected key, CI cannot use a passphrase), commit `cosign.pub`, store `cosign.key` as the environment secret `SIGNING_SECRET`, enable GitHub Actions. A new image's ghcr package is private after its first publish: Kevin sets it public in the web UI (not possible via API) so distrobox can pull it without login.
- Renovate and branch protection: automerge of base-digest bumps only works if protection on `main` lets it through; Renovate's own branches fail `require-testing-branch`, so those digest PRs need a manual merge or a ruleset exception (assumption, unverified until a Renovate PR exists; the Renovate app must be installed).
- Base digest pinning: Renovate (`config:best-practices`, Containerfile manager matching every `*/Containerfile`) pins the `FROM` digest of `ghcr.io/ublue-os/**` bases and opens update PRs; digest bumps of the base automerge. Actions are pinned by SHA and updated by Renovate and Dependabot.
- Commits: on `testing`, explicit paths only (never `git add -A`), message says why, trailer `Co-Authored-By` from the session reminder, wrapped in `~/.config/scripts/with-lock.sh repo-fedora-toolbox git commit ...`.

## Deliberately not in the images

SDKMAN, nvm, Node, Java (runtime installs into the shared home); anything in `/home`; Terra or other repos beyond the base's; `ffmpeg-free-devel`; any OS-image tooling (bootc, rpm-ostree, kernel, bootloader, ISO/disk builders).
