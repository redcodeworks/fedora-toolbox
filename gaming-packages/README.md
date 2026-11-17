# gaming-packages

The gaming package lists of [octarine-images](https://github.com/redcodeworks/octarine-images) (Steam, gamescope, MangoHud, GameMode, Sunshine and friends) and their installers, as a tiny signed image. The `fedora-gaming` box and the gaming host image install the same lists from here, so there is one place to edit.

The image contains only the lists `/fedora.txt`, `/negativo17.txt` and `/copr.txt`, the installers `/install.sh` and `/install-copr.sh`, and this file as `/README`. It has no shell and no packages; it is meant to be bind-mounted into a build.

## Use it in a Containerfile

Pin the image by digest (find the current digests under the package page `ghcr.io/redcodeworks/gaming-packages`, or with `skopeo inspect --no-tags docker://ghcr.io/redcodeworks/gaming-packages:latest`):

```Dockerfile
FROM ghcr.io/redcodeworks/gaming-packages@sha256:<digest> AS pkgs

FROM <your base image>
RUN --mount=type=bind,from=pkgs,source=/,target=/gaming-packages \
    bash /gaming-packages/install.sh /gaming-packages/fedora.txt && \
    ENABLE_REPO=fedora-multimedia bash /gaming-packages/install.sh /gaming-packages/negativo17.txt
```

Tags: `latest` (the current release) and `latest-<YYYYMMDD>-<short sha>` (dated, never moves); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag, so a change of the list reaches your image only when you bump the digest.

Needs: `dnf5` and root in the consuming image (a Fedora base). Each installer call is one strict transaction: a package that cannot be installed fails your build, nothing is skipped. They clean the dnf caches and logs at the end.

## The three lists

Install them in this order, each in its own call, so each source class stays separate:

| List | Source | What it assumes |
|---|---|---|
| `fedora.txt` | Fedora's own repositories | nothing beyond the default Fedora repositories |
| `negativo17.txt` | negativo17 (Steam) | the negativo17 repository `fedora-multimedia` is configured in your image (the Universal Blue base ships it, disabled); it stays disabled, the call enables it with `ENABLE_REPO=fedora-multimedia` |
| `copr.txt` | COPR, one exact version per package | the `dnf5-plugins` package is installed (it provides `dnf5 copr`) |

`fedora.txt` and `negativo17.txt` use `install.sh`. `copr.txt` uses `install-copr.sh`, which enables each COPR, installs the pinned package and disables the COPR again; a failure fails your build:

```Dockerfile
RUN --mount=type=bind,from=pkgs,source=/,target=/gaming-packages \
    bash /gaming-packages/install-copr.sh /gaming-packages/copr.txt
```

## List syntax

`fedora.txt` and `negativo17.txt`: one entry per line; blank lines and `#` comments are ignored. `name`, `name.arch`, `@group-id`, or `a|b` alternatives (the first one that exists in the enabled repositories is installed; none existing fails). `EXCLUDE="name1 @group"` in the environment drops entries (printed); `ENABLE_REPO="id1 id2"` enables those (normally disabled) repositories for that call only; `NO_CLEANUP=1` skips the cleanup.

`copr.txt`: one entry per line, `owner/project:name-version-release` with the exact version and release (the package name is case sensitive); an entry without a version and release is rejected.

Every `name.i686` entry is paired with an explicit `name.x86_64` entry (a bare name next to an i686 one would install only the i686 package on a host).

What the lists assume of the consuming image:
- Mesa for both x86_64 and i686 is available. Fedora ships both, and so does negativo17 (`fedora-multimedia`), which the Universal Blue base enables. The Terra cleanup `fedora-gaming` does in its own build is not part of this image.
- `steam` comes from negativo17 (`steam-1.0.0.87-4.fc45` on 2026-11-16), and negativo17 is newer than Fedora for Steam's own dependencies, so the `negativo17.txt` call also brings in these packages from negativo17 instead of Fedora (dnf5 dry run on Fedora 45, 2026-11-16): the Mesa set for both architectures (`mesa-dri-drivers`, `mesa-filesystem`, `mesa-libEGL`, `mesa-libGL`, `mesa-libgbm`, `mesa-vulkan-drivers`: 26.2.7 against Fedora's 26.2.6), `libva`, the codec libraries (`libavcodec`, `libavutil`, `libswresample`, `openh264`, `libheif`, `x264-libs`, `x265-libs`, `libfdk-aac`, `vvdec-libs`, `vvenc-libs` and similar, mostly both architectures), `LCEVCdec`, `gstreamer1-plugins-bad`, `intel-mediasdk` and `svt-jpeg-xs`: about 60 packages in all. Install `fedora.txt` first. The list was resolved with only Steam requested; with `fedora.txt` already installed, dnf may leave some of these on Fedora's build, so check `dnf5 repoquery --installed --queryformat '%{name} %{from_repo}\n'` (or `rpm -qa`) if the origin matters to you.

## Verify the signature

Every tag and digest is signed with the repository's cosign key:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/gaming-packages@sha256:<digest>
```

The public key (`cosign.pub`, also at https://raw.githubusercontent.com/redcodeworks/fedora-toolbox/main/cosign.pub):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEm5Ya8bLNlOohvzXBXsi/ZoyMFonO
XPhFf/egYl0wLWz8tclnZwlkwVLd70PGbdgru6QauYOgoHKBJi+9d/o93w==
-----END PUBLIC KEY-----
```

## License

Apache-2.0.
