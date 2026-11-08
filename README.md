# fedora-toolbox

This repo builds toolbox images only: [distrobox](https://distrobox.it)/container development environments. Each top-level directory with a `Containerfile` is one image; the image name is the directory name, published to `ghcr.io/redcodeworks/<name>`. OS and bootc images live in their own repos.

## Images

| Image | Description |
|---|---|
| [`fedora-toolbox`](fedora-toolbox/) | Fedora development toolbox for distrobox with a shared home: build chain, `-devel` libraries, `uv`, `rustup`, `fish` (package list: [`dev.txt`](fedora-toolbox/packages/dev.txt)) |

Tags, for every image: `latest` and `latest-<YYYYMMDD>-<short sha>` (a dated tag to pin) from `main`; `testing` and `testing-<YYYYMMDD>-<short sha>` from the `testing` branch, for trying changes first.

## Use

```bash
distrobox create --name fedora-toolbox --image ghcr.io/redcodeworks/fedora-toolbox:latest
distrobox enter fedora-toolbox
```

Use `:testing` instead of `:latest` to try a box from the testing build. On nox the host recipe `ujust dev-toolbox` (in the octarine-os repo) creates the box. The images hold nothing user-specific, so a box works with the host's real home; SDKMAN and nvm are installed into it at runtime.

## Verify

Images are signed with cosign:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/fedora-toolbox:latest
```

## Add an image

```bash
just new-image <name>      # scaffolds <name>/ (toolbox base, package list, build.sh, smoke test)
just build <name> && just smoke <name>
```

Then edit `<name>/packages/dev.txt` and `<name>/tests/smoke.sh`. `just list` shows the images, `just lint` checks the repo.

## Contributing

`main` is protected: work on `testing` and open a pull request; CI is the test. Design notes are in [`CLAUDE.md`](CLAUDE.md).

## License

Apache-2.0, see `LICENSE`.
