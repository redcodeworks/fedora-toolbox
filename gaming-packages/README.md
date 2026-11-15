# gaming-packages

The package manifest of the `fedora-gaming` image of [fedora-toolbox](https://github.com/redcodeworks/fedora-toolbox) (Steam, gamescope, MangoHud, GameMode) and its installer, as a tiny signed image. `fedora-gaming` is built from the same file, so the published manifest and the toolbox cannot drift.

The image contains only `/gaming.txt` (the list), `/install.sh` (the installer) and this file as `/README`. It has no shell and no packages; it is meant to be bind-mounted into a build.

## Use it in a Containerfile

Pin the image by digest (find the current digests under the package page `ghcr.io/redcodeworks/gaming-packages`, or with `skopeo inspect --no-tags docker://ghcr.io/redcodeworks/gaming-packages:latest`):

```Dockerfile
FROM ghcr.io/redcodeworks/gaming-packages@sha256:<digest> AS pkgs

FROM <your base image>
RUN --mount=type=bind,from=pkgs,source=/,target=/gaming-packages \
    bash /gaming-packages/install.sh
```

Tags: `latest` (the current release) and `latest-<YYYYMMDD>-<short sha>` (dated, never moves); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag, so a change of the list reaches your image only when you bump the digest.

Needs: `dnf5` and root in the consuming image (a Fedora base). The installer runs one strict `dnf5 install`: a package or group that cannot be installed fails your build, nothing is skipped (except in the optional tier below). It cleans the dnf caches and logs at the end.

## List syntax

One entry per line; blank lines and `#` comments are ignored. `name`, `name.arch`, `@group-id`, or `a|b` alternatives (the first one that exists in the enabled repositories is installed; none existing fails). `EXCLUDE="name1 @group"` in the environment drops entries (printed); `NO_CLEANUP=1` skips the cleanup.

The list assumes Fedora's Mesa for both x86_64 and i686 and the RPM Fusion nonfree repository (for `steam`); the Terra cleanup `fedora-gaming` does in its own build is not part of this image.

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
