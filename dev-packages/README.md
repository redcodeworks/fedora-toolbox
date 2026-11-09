# dev-packages

The developer package list of [fedora-toolbox](https://github.com/redcodeworks/fedora-toolbox) and its installer, as a tiny signed image. The `dev-toolbox` image and the `octarine-os-dx` image install the same list from here, so there is one place to edit.

The image contains only `/dev.txt` (the list), `/install.sh` (the installer) and this file as `/README`. It has no shell and no packages; it is meant to be bind-mounted into a build.

## Use it in a Containerfile

Pin the image by digest (find the current digests under the package page `ghcr.io/redcodeworks/dev-packages`, or with `skopeo inspect --no-tags docker://ghcr.io/redcodeworks/dev-packages:latest`):

```Dockerfile
FROM ghcr.io/redcodeworks/dev-packages@sha256:<digest> AS devpkgs

FROM <your base image>
RUN --mount=type=bind,from=devpkgs,source=/,target=/dev-packages \
    bash /dev-packages/install.sh
```

Tags: `latest` (the current release) and `latest-<YYYYMMDD>-<short sha>` (dated, never moves); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag, so a change of the list reaches your image only when you bump the digest.

Needs: `dnf5` and root in the consuming image (a Fedora base). The installer runs one strict `dnf5 install`: a package or group that cannot be installed fails your build, nothing is skipped. It cleans the dnf caches and logs at the end.

## List syntax (`/dev.txt`)

One entry per line; blank lines and `#` comments are ignored.

| Entry | Meaning |
|---|---|
| `name` | a package |
| `@group-id` | a package group |
| `a\|b` | alternatives for a package whose name differs between Fedora releases: the first one that exists in the enabled repositories is installed; if none exists the build fails (example: `libgit2_1.9-devel\|libgit2-devel`, the name on Fedora 45 first, then the Fedora 44 name) |

## Excluding entries

```Dockerfile
RUN --mount=type=bind,from=devpkgs,source=/,target=/dev-packages \
    EXCLUDE="rocm-hip hipcc" bash /dev-packages/install.sh
```

`EXCLUDE` is a space-separated list of names (or `@groups`). An entry is dropped when any of its alternatives is listed; the dropped entries are printed. To use a list of your own, pass its path: `bash /dev-packages/install.sh /path/to/list.txt`.

## Verify the signature

Every tag and digest is signed with the repository's cosign key:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/dev-packages@sha256:<digest>
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
