# extest-bin

`libextest.so` from [extest](https://github.com/Supreeeme/extest) (MIT), built from one pinned upstream commit (see `/SOURCE`), as a tiny signed image. Steam loads it with `LD_PRELOAD` (as a Flatpak too). x86_64 hosts only.

The image holds `/lib64/libextest.so` (64-bit) and `/lib/libextest.so` (32-bit, because Steam is a 32-bit application), `/LICENSES/`, `/SOURCE` (repository, commit, build date) and `/BUILDINFO`. It has no shell.

## Use it in a Containerfile

Pin the image by digest (find the current digests under the package page `ghcr.io/redcodeworks/extest-bin`, or with `skopeo inspect --no-tags docker://ghcr.io/redcodeworks/extest-bin:latest`):

```Dockerfile
FROM ghcr.io/redcodeworks/extest-bin@sha256:<digest> AS extest

FROM <your Fedora 45 based image>
COPY --from=extest /lib64/libextest.so /usr/lib64/libextest.so
COPY --from=extest /lib/libextest.so /usr/lib/libextest.so
# then LD_PRELOAD=/usr/$LIB/libextest.so loads the 64-bit or the 32-bit one per process
```

Tags: `latest` (the current release), `latest-<YYYYMMDD>-<short sha>` (dated, never moves), `commit-<short sha>, for example `commit-cb77cd4`` (the upstream version it was built from); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag.

Both libraries are built with `cargo build --release --locked --target <x86_64 or i686>-unknown-linux-gnu` on Fedora 45 against its glibc. The build checks the ELF class of each (64-bit x86-64, 32-bit Intel 80386); whether Steam picks it up is only verifiable on a real machine.

## Verify the signature

Every tag and digest is signed with the repository's cosign key:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/extest-bin@sha256:<digest>
```

The public key (`cosign.pub`, also at https://raw.githubusercontent.com/redcodeworks/fedora-toolbox/main/cosign.pub):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEm5Ya8bLNlOohvzXBXsi/ZoyMFonO
XPhFf/egYl0wLWz8tclnZwlkwVLd70PGbdgru6QauYOgoHKBJi+9d/o93w==
-----END PUBLIC KEY-----
```

## License

The repository is Apache-2.0. The binaries carry their upstream licenses (MIT); the texts are in `/LICENSES`. Statically linked Rust dependencies have licenses of their own, listed in the upstream `Cargo.lock`.
