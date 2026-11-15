# datastore-images

The container images of the lakehouse datastore (PostgreSQL, Valkey, SeaweedFS, Kafka), pinned by exact tag and digest in one small text file, `images.txt`, published as a tiny signed image by [fedora-toolbox](https://github.com/redcodeworks/fedora-toolbox). The image contains only `/images.txt` and this file as `/README`; it has no shell and no packages.

## The file

One line per image, `#` comments and blank lines allowed:

```
<name> <image>:<tag>@sha256:<digest>
```

- Names: `postgresql`, `valkey`, `seaweedfs`, `kafka`, each exactly once.
- Tags are exact versions, never `latest` and never a floating major tag.
- The digest is the manifest sha256 of the tag (`skopeo inspect --raw docker://<image>:<tag> | sha256sum`).

## Change a version

The file is edited by hand; nothing bumps it automatically. Change the tag and the digest together on a feature branch, run `tests/datastore-images.sh` (or `just test`), and open a pull request into `testing`. A merge publishes a new `datastore-images` image.

## Use it

The octarine-os developer image pins this image by digest, copies `images.txt` out of it, renders its datastore Quadlets from it, and bumps the digest of this image with its own weekly workflow:

```Dockerfile
FROM ghcr.io/redcodeworks/datastore-images@sha256:<digest> AS datastore
...
RUN --mount=type=bind,from=datastore,source=/,target=/datastore-images \
    cp /datastore-images/images.txt /somewhere/
```

Tags: `latest` (the current release) and `latest-<YYYYMMDD>-<short sha>` (dated, never moves); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag.

## Verify the signature

Every tag and digest is signed with the repository's cosign key:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/datastore-images@sha256:<digest>
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
