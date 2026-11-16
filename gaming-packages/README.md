# gaming-packages

The gaming package lists of [octarine-images](https://github.com/redcodeworks/octarine-images) (Steam, gamescope, MangoHud, GameMode, Sunshine and friends) and their installers, as a tiny signed image. The `fedora-gaming` box and the gaming host image install the same lists from here, so there is one place to edit.

The image contains only the lists `/fedora.txt`, `/rpmfusion.txt` and `/copr.txt`, the installers `/install.sh` and `/install-copr.sh`, and this file as `/README`. It has no shell and no packages; it is meant to be bind-mounted into a build.

## Use it in a Containerfile

Pin the image by digest (find the current digests under the package page `ghcr.io/redcodeworks/gaming-packages`, or with `skopeo inspect --no-tags docker://ghcr.io/redcodeworks/gaming-packages:latest`):

```Dockerfile
FROM ghcr.io/redcodeworks/gaming-packages@sha256:<digest> AS pkgs

FROM <your base image>
RUN --mount=type=bind,from=pkgs,source=/,target=/gaming-packages \
    bash /gaming-packages/install.sh /gaming-packages/fedora.txt && \
    bash /gaming-packages/install.sh /gaming-packages/rpmfusion.txt
```

Tags: `latest` (the current release) and `latest-<YYYYMMDD>-<short sha>` (dated, never moves); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag, so a change of the list reaches your image only when you bump the digest.

Needs: `dnf5` and root in the consuming image (a Fedora base). Each installer call is one strict transaction: a package that cannot be installed fails your build, nothing is skipped. They clean the dnf caches and logs at the end.

## The three lists

Install them in this order, each in its own call, so each source class stays separate:

| List | Source | What it assumes |
|---|---|---|
| `fedora.txt` | Fedora's own repositories | nothing beyond the default Fedora repositories |
| `rpmfusion.txt` | RPM Fusion nonfree (Steam) | the RPM Fusion nonfree repository is enabled in your image (enable it before the call; you may disable it again afterwards) |
| `copr.txt` | COPR, one exact version per package | the `dnf5-plugins` package is installed (it provides `dnf5 copr`) |

`fedora.txt` and `rpmfusion.txt` use `install.sh`. `copr.txt` uses `install-copr.sh`, which enables each COPR, installs the pinned package and disables the COPR again; a failure fails your build:

```Dockerfile
RUN --mount=type=bind,from=pkgs,source=/,target=/gaming-packages \
    bash /gaming-packages/install-copr.sh /gaming-packages/copr.txt
```

## List syntax

`fedora.txt` and `rpmfusion.txt`: one entry per line; blank lines and `#` comments are ignored. `name`, `name.arch`, `@group-id`, or `a|b` alternatives (the first one that exists in the enabled repositories is installed; none existing fails). `EXCLUDE="name1 @group"` in the environment drops entries (printed); `NO_CLEANUP=1` skips the cleanup.

`copr.txt`: one entry per line, `owner/project:name-version-release` with the exact version and release (the package name is case sensitive); an entry without a version and release is rejected.

The lists assume Fedora's Mesa for both x86_64 and i686. The Terra cleanup `fedora-gaming` does in its own build is not part of this image.

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
