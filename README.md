# fedora-toolbox

Ready-made development and gaming containers for [distrobox](https://distrobox.it), published as signed images on GitHub's container registry. Each one is a normal Fedora box with the tools already installed, so you skip the setup and keep your home folder.

| Image | What it is |
|---|---|
| [`fedora-toolbox`](fedora-toolbox/) | Development box: compilers and build tools, common `-devel` libraries, `uv`, `rustup`, `fish` (list: [`dev.txt`](dev-packages/dev.txt)) |
| [`dev-packages`](dev-packages/) | Not a box: the developer package list above and its installer as a small signed image, so other Fedora-based images can install the same tools (see its README) |
| [`fedora-gaming`](fedora-gaming/) | Gaming box: Steam, gamescope, MangoHud, GameMode on Fedora's Mesa (list: [`gaming.txt`](gaming-packages/gaming.txt)) |
| [`gaming-packages`](gaming-packages/) | Not a box: the gaming package list and its installer as a small signed image, for other Fedora-based images (see its README) |
| [`dna-toolbox`](dna-toolbox/) | Data, analytics and AI box: Python and JVM data tooling, GPU toolkits (ROCm or CUDA) installed on demand with `dna-gpu`, plus `dna-stack` to start lakehouse server containers (Postgres, SeaweedFS, Lakekeeper, Trino, and more) on your host from the box; the heavier services (Kafka Connect, Airflow, Superset) are built on your machine the first time you start them; work in progress |
| [`dna-packages`](dna-packages/) | Not a box: the package lists of `dna-toolbox` and their installer as a small signed image, for other Fedora-based images (see its README) |
| [`scx-bin`](scx-bin/) | Not a box: the `scx_rusty` and `scx_lavd` sched_ext CPU schedulers built from a pinned upstream release, as a small signed image other images can copy from |
| [`extest-bin`](extest-bin/) | Not a box: `libextest.so` ([extest](https://github.com/Supreeeme/extest)) built from a pinned upstream commit (x86_64), as a small signed image |

## Requirements

- [distrobox](https://distrobox.it) with podman (or docker)
- An x86_64 (amd64) computer: the images are not built for other architectures such as Apple Silicon or ARM
- Optional: [`cosign`](https://github.com/sigstore/cosign) to verify the images, [`just`](https://github.com/casey/just) to work on the repo

## Install and usage

```bash
distrobox create --name fedora-toolbox --image ghcr.io/redcodeworks/fedora-toolbox:latest
distrobox enter fedora-toolbox
```

The images are built for x86_64 (amd64) hosts only. Use the `fedora-gaming` image the same way. `:latest` is the current release; `latest-<YYYYMMDD>-<short sha>` pins a date; `:testing` is the preview. The images contain nothing personal, so a box works with your real home. Language managers such as SDKMAN and nvm are not included: install them inside the box.

The `fedora-toolbox` box now installs its tools from the same list that other images can reuse (the `dev-packages` entry above), and one package that was renamed between Fedora releases (`libgit2`) now works on both. Nothing changes in how you create or use the box.

To check a download:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/fedora-toolbox:latest
```

## Contributing

Issues and pull requests are welcome, though I only maintain this for my own use. Work on a branch and open a pull request into `testing`; changes reach `main` in a later pull request from `testing`. `just list` shows the images, `just lint` checks the repo, and `just new-image <name>` starts a new one.

## License

Apache-2.0, see [`LICENSE`](LICENSE).

## Credits

- [Universal Blue](https://universal-blue.org) and its [toolboxes](https://github.com/ublue-os/toolboxes) provide the base image, and the [image-template](https://github.com/ublue-os/image-template) this repo started from.
- [Fedora](https://fedoraproject.org) for the packages, [distrobox](https://distrobox.it) and [podman](https://podman.io) for the containers, [cosign](https://github.com/sigstore/cosign) for signing.
- Written with [Claude](https://claude.com/claude-code) (Anthropic's coding assistant).

## About this repo

This is a personal project for my own machine, assisted by Claude, so please excuse the slop. I have only tested it on my own setup and will not actively maintain it beyond my own needs. If you find something valuable here, I encourage you to fork it and make it yours.
