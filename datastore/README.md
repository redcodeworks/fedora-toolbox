# datastore

The `datastore` box is ONE distrobox with its own systemd that runs Postgres, Valkey, SeaweedFS and Kafka as ordinary units, on the `lakehouse` network under the aliases the other services already use (`pgsql`, `postgresql`, `valkey`, `seaweedfs`, `kafka`), with its data in plain directories under your home; it is for local development only, not high availability.

## Requirements

- [distrobox](https://distrobox.it) 1.8 or newer with rootless podman, on an x86_64 computer
- A podman network called `lakehouse`

## Create and use

```bash
podman network exists lakehouse || podman network create lakehouse
distrobox assemble create --file distrobox.ini      # the file in this directory
distrobox enter datastore -- datastore setup         # once: directories, passwords, config, units
distrobox enter datastore -- datastore start
distrobox enter datastore -- datastore status
```

Ports are published on loopback only: Postgres 5432, Valkey 6379, SeaweedFS S3 8333 and master 9333, the filer on 8889, Kafka 9092. After a box restart the four services come back by themselves.

The `datastore` command: `setup`, `start|stop|restart [NAME..]`, `enable|disable`, `status`, `logs NAME`, `psql`, `valkey-cli`, `secrets list|show|export`, `backup DIR [--stop]`, `restore FILE`. `datastore --help` lists them.

What runs: PostgreSQL 17 (`wal_level=logical`, scram passwords), Valkey 9 (password, append-only file), SeaweedFS 4.53 (master, volume, filer and an S3 gateway with generated keys), Kafka 4.3.2 (one KRaft node, advertised as `kafka:9092`). Data: `$HOME/.local/share/datastore/{postgres,valkey,seaweed,kafka}`. Config and the generated secrets: `$HOME/.config/datastore`.

## Passwords and S3 keys

`datastore setup` generates a Postgres password, a Valkey password and an S3 access/secret key pair (never overwriting existing ones) and keeps them in `$HOME/.config/datastore/secrets/`. Containers that depend on the datastore read podman secrets with the same names as before (`postgresql-password`, `valkey-password`, `seaweedfs-s3-config`); `datastore secrets export` creates them on the host for you (`--replace` overwrites existing ones).

## Move from the Podman services

The old services keep working until you cut over. To move:

1. Create and set up the box as above, then `datastore start`. Do not export the secrets yet.
2. Dump the old Postgres: `podman exec pgsql pg_dumpall -U postgres > ~/pg-old.sql`.
3. Stop the old services (`systemctl --user stop datastore-pod kafka-pod`) so ports 5432 and the others are free, then restart the box so it publishes them.
4. `datastore restore ~/pg-old.sql` loads all databases and roles. The box keeps its own `postgres` password; other roles keep the passwords they had. Replication slots do not survive a dump: recreate them (Debezium does when its connector restarts).
5. Valkey, SeaweedFS and Kafka data are plain directory copies and need the same versions: stop the box service (`datastore stop valkey`), copy the old volume contents into `$HOME/.local/share/datastore/valkey` (and `seaweed`, `kafka`), start it again. Old volumes live under `podman volume inspect NAME` (`Mountpoint`).
6. Re-issue the secrets: `datastore secrets export --replace`, then recreate the secrets that other containers derived from the old passwords (for example connection URLs) and restart them. S3 keys and the Valkey password are new.

A backup is `datastore backup DIR` (a `pg_dumpall` file; the Valkey, SeaweedFS and Kafka directories as tar files, which need `--stop` to stop them briefly). Restore a dump into a fresh box with `datastore restore FILE`; restore the tar files by stopping the service and unpacking into `$HOME/.local/share/datastore`. Backups do not include the secrets directory.

## Credits

[Fedora](https://fedoraproject.org), [PostgreSQL](https://www.postgresql.org), [Valkey](https://valkey.io), [SeaweedFS](https://github.com/seaweedfs/seaweedfs), [Apache Kafka](https://kafka.apache.org), [distrobox](https://distrobox.it).
