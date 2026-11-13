# scx-bin

The `scx_rusty` and `scx_lavd` [sched_ext](https://github.com/sched-ext/scx) CPU schedulers, built from one pinned upstream release (see `/SOURCE`), as a tiny signed image. An OS image can copy them in by digest instead of compiling anything. Fedora's own `scx_rusty` is older and is not used.

The image holds `/bin/scx_rusty`, `/bin/scx_lavd`, `/LICENSES/` (the upstream license texts), `/SOURCE` (repository, tag, 40-character commit, build date) and `/BUILDINFO` (rustc, cargo, clang, glibc and the shared libraries the binaries need). It has no shell.

## Use it in a Containerfile

Pin the image by digest (find the current digests under the package page `ghcr.io/redcodeworks/scx-bin`, or with `skopeo inspect --no-tags docker://ghcr.io/redcodeworks/scx-bin:latest`):

```Dockerfile
FROM ghcr.io/redcodeworks/scx-bin@sha256:<digest> AS scx

FROM <your Fedora 45 based image>
COPY --from=scx /bin/scx_rusty /usr/bin/scx_rusty
COPY --from=scx /bin/scx_lavd /usr/bin/scx_lavd
# or, without a stage:
# COPY --from=ghcr.io/redcodeworks/scx-bin@sha256:<digest> /bin/scx_lavd /usr/bin/scx_lavd
```

Tags: `latest` (the current release), `latest-<YYYYMMDD>-<short sha>` (dated, never moves), `v<upstream version>, for example `v1.1.4`` (the upstream version it was built from); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag.

The binaries are built on Fedora 45 against its glibc and link `libbpf`, `libelf`, `zlib` and `zstd` dynamically (the exact list is in `/BUILDINFO`), so use them on Fedora 45 or newer with those libraries installed. Loading a scheduler needs a kernel with `sched_ext` and root; the build only checks that the binaries start (`--version`), because a BPF scheduler cannot be loaded on a CI runner.

## Verify the signature

Every tag and digest is signed with the repository's cosign key:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/scx-bin@sha256:<digest>
```

The public key (`cosign.pub`, also at https://raw.githubusercontent.com/redcodeworks/fedora-toolbox/main/cosign.pub):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEm5Ya8bLNlOohvzXBXsi/ZoyMFonO
XPhFf/egYl0wLWz8tclnZwlkwVLd70PGbdgru6QauYOgoHKBJi+9d/o93w==
-----END PUBLIC KEY-----
```

## License

The repository is Apache-2.0. The binaries carry their upstream licenses (GPL-2.0-only); the texts are in `/LICENSES`. Statically linked Rust dependencies have licenses of their own, listed in the upstream `Cargo.lock`.
