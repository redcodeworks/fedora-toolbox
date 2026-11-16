# datastore-images

The lakehouse datastore as a small signed bundle, published by [fedora-toolbox](https://github.com/redcodeworks/fedora-toolbox): PostgreSQL, Valkey and SeaweedFS (one pod) and Kafka (another pod) as rootless Podman services, stopped until you start them. The bundle holds the pinned container images, the service definitions (Quadlet files) and one command, `datastore`, that installs them into your home, creates the secrets and starts, stops, updates and backs the services up. It has no shell and no packages; nothing in it needs root.

## Requirements

- Linux with Podman (rootless) and a user systemd (`systemctl --user`)
- `bash`, `sed`, `awk` and the usual core tools (nothing else is called)

## What is in it

```
images.txt              the pinned images (the one file edited by hand)
quadlets/               the service definitions, with the image references left blank
lib/render.sh           fills the references in from images.txt
lib/datastore.sh        helpers of the command
bin/datastore           the command
README                  this file
```

`bin/datastore` finds the other files in the directory above it, so it runs the same from a checkout of the repository and from the extracted image.

## Use it

Get the bundle out of the image (this pulls the image into your Podman storage and checks its signature first when your containers policy requires one, see below), then run the command from where you put it:

```bash
img=ghcr.io/redcodeworks/datastore-images:latest
podman pull "$img"
cid=$(podman create "$img" /images.txt)
mkdir -p ~/datastore-bundle && podman export "$cid" | tar -x -C ~/datastore-bundle
podman rm "$cid"

~/datastore-bundle/bin/datastore --help
~/datastore-bundle/bin/datastore install      # place the units in $HOME/.config/containers/systemd (undo: uninstall)
~/datastore-bundle/bin/datastore setup        # create the missing secrets (random values, never printed)
~/datastore-bundle/bin/datastore start        # PostgreSQL, Valkey and SeaweedFS; `start kafka` for Kafka
```

The command also does `status`, `logs SERVICE`, `stop`, `setup --status|--pin|--unpin|--update|--backup DIR` and `uninstall`; `--help` explains each one. Installing starts nothing, and uninstalling never deletes your volumes or secrets (it prints the commands that would, for you to run on purpose). Running `install` again after pulling a newer bundle updates the units and leaves your data and secrets alone.

## Change a version

Edit `images.txt` by hand (nothing bumps it automatically). One line per image, `#` comments and blank lines allowed:

```
<name> <image>:<tag>@sha256:<digest>
```

- Names: `postgresql`, `valkey`, `seaweedfs`, `kafka`, each exactly once.
- Tags are exact versions, never `latest` and never a floating major tag.
- The digest is the manifest sha256 of the tag (`skopeo inspect --raw docker://<image>:<tag> | sha256sum`).

Change the tag and the digest together on a feature branch, run `just test`, and open a pull request into `testing`. A merge publishes a new bundle.

## Verify the signature

Every tag and digest is signed with the repository's cosign key:

```bash
cosign verify --key cosign.pub ghcr.io/redcodeworks/datastore-images@sha256:<digest>
```

Podman can check the same signature itself while pulling. Add this to `/etc/containers/policy.json` (or the file you pass to `podman pull --signature-policy`), with `cosign.pub` saved at the path shown:

```json
"docker": {
  "ghcr.io/redcodeworks/datastore-images": [
    { "type": "sigstoreSigned", "keyPath": "/path/to/cosign.pub", "signedIdentity": { "type": "matchRepository" } }
  ]
}
```

and tell it to read the signature stored next to the image, in `/etc/containers/registries.d/datastore-images.yaml`:

```yaml
docker:
  ghcr.io/redcodeworks/datastore-images:
    use-sigstore-attachments: true
```

Without the second file a signed image is rejected ("a signature was required, but no signature exists"); with a wrong key it is rejected too.

The public key (`cosign.pub`, also at https://raw.githubusercontent.com/redcodeworks/fedora-toolbox/main/cosign.pub):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEm5Ya8bLNlOohvzXBXsi/ZoyMFonO
XPhFf/egYl0wLWz8tclnZwlkwVLd70PGbdgru6QauYOgoHKBJi+9d/o93w==
-----END PUBLIC KEY-----
```

Tags: `latest` (the current release) and `latest-<YYYYMMDD>-<short sha>` (dated, never moves); `testing` and `testing-<YYYYMMDD>-<short sha>` are the preview. Pin the digest, not a tag, when you need a fixed version.

## License

Apache-2.0.
