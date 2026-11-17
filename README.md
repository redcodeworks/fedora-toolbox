# octarine-images

Ready-made containers for [distrobox](https://distrobox.it) (development, gaming, data work), published as signed images on GitHub's container registry. Each one is a normal Fedora box with the tools already installed, so you skip the setup and keep your home folder.

| Box | What it is |
|---|---|
| [`fedora-toolbox`](fedora-toolbox/) | Development box: compilers and build tools, common `-devel` libraries, `uv`, `rustup`, `fish`; the same developer tools as the dx edition of octarine-os |
| [`fedora-gaming`](fedora-gaming/) | Gaming box: Steam, gamescope, MangoHud, GameMode and the Vulkan stack on Fedora's Mesa; the same games as the gx edition of octarine-os, minus Sunshine |
| [`dna-toolbox`](dna-toolbox/) | Data, analytics and AI box: Python and JVM data tooling, GPU toolkits (ROCm or CUDA) installed on demand with `dna-gpu`, plus `dna-stack` to start lakehouse server containers (Postgres, SeaweedFS, Lakekeeper, Trino, and more) on your host from the box; work in progress |
| [`datastore-images`](datastore-images/) | The lakehouse datastore (PostgreSQL, Valkey, SeaweedFS, Kafka as rootless Podman services) as a small signed bundle with a `datastore` command to install, set up and run it (see its README); not a box yet |
| [`datastore`](datastore/) | The lakehouse datastore as one box: PostgreSQL, Valkey, SeaweedFS and Kafka running side by side in a distrobox with its own systemd, for local development (see its README) |

## Build status

| Images | main | testing |
|---:|---:|---:|
| all | [![images, main](https://github.com/redcodeworks/octarine-images/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/redcodeworks/octarine-images/actions/workflows/build.yml?query=branch%3Amain) | [![images, testing](https://github.com/redcodeworks/octarine-images/actions/workflows/build.yml/badge.svg?branch=testing)](https://github.com/redcodeworks/octarine-images/actions/workflows/build.yml?query=branch%3Atesting) |

All the boxes (`fedora-toolbox`, `fedora-gaming`, `dna-toolbox`, `datastore-images` and `datastore`) are built by one workflow, so each badge covers all of them together: it turns red when any one fails to build or sign. The quick checks on a work branch are not shown here, since they only run before a change reaches `testing`.

## Requirements

- [distrobox](https://distrobox.it) with podman (or docker)
- An x86_64 (amd64) computer: the images are not built for other architectures such as Apple Silicon or ARM
- Optional: [`cosign`](https://github.com/sigstore/cosign) to verify the images, [`just`](https://github.com/casey/just) to work on the repo

## Install and usage

```bash
distrobox create --name fedora-toolbox --image ghcr.io/redcodeworks/fedora-toolbox:latest
distrobox enter fedora-toolbox
```

Use the `fedora-gaming` and `dna-toolbox` images the same way. The `datastore` box needs a few extra options and a setup step: see [`datastore/README.md`](datastore/README.md). `:latest` is the current release; `latest-<YYYYMMDD>-<short sha>` pins a date; `:testing` is the preview. The images contain nothing personal, so a box works with your real home. Language managers such as SDKMAN and nvm are not included: install them inside the box.

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
