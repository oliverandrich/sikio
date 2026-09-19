# Operations: Elixir release or Docker

Both paths use the same Phoenix release, the same migrations and the same PostgreSQL schema.
A release carries the Erlang runtime, so the target server needs no Mix. Build native releases
on the same operating system and architecture as the target. The Dockerfile builds a Linux
release instead. Reference: [Phoenix releases](https://phoenix.hexdocs.pm/releases.html).

## Runtime configuration

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | `ecto://USER:URL_ENCODED_PASSWORD@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret`; keep it permanently |
| `PHX_HOST` | Public, stable hostname without scheme or port |
| `PORT` | Internal HTTP port, 4000 by default |
| `PHX_BIND_IP` | `127.0.0.1` by default, `0.0.0.0` in a container |
| `POOL_SIZE` | Database connections, 10 by default |

Starting through `bin/server` enables Phoenix by itself. With `bin/sikio start`, also set
`PHX_SERVER=true`. The public URL is HTTPS on port 443. Use a protected network path for a
remote database; this template configures no database TLS. Compose keeps PostgreSQL on the
internal network.

Keep `SECRET_KEY_BASE`, the runtime configuration and the database backups apart from the
repository. Backups contain authentication data as well. The hostname has to stay stable,
because passkeys are bound to the domain they were created on.

## Native installation

1. Provide PostgreSQL 18 and a dedicated database with an owner.
2. Build on a matching machine from a reviewed commit:

   ```sh
   mise install
   mise run release
   ```

3. Copy all of `_build/prod/rel/sikio` to the target server, for example to
   `/opt/sikio/releases/COMMIT`. No `deps` and no sources are needed.
4. Set the variables from the table above for the service. The database has to exist already.
5. Migrate first, then start:

   ```sh
   /opt/sikio/current/bin/migrate
   /opt/sikio/current/bin/server
   ```

`current` is a symlink to the chosen release directory. An example for systemd, with the
`sikio` user and the files created beforehand:

```ini
[Unit]
Description=Sikio media library
After=network-online.target
Wants=network-online.target

[Service]
User=sikio
WorkingDirectory=/opt/sikio/current
EnvironmentFile=/etc/sikio/runtime.env
ExecStart=/opt/sikio/current/bin/server
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

`runtime.env` holds `NAME=VALUE` lines without `export`; restrict it to the service user.
Run migrations deliberately as a separate step with the same environment.

## Docker Compose

Docker with Compose v2 is required. The Dockerfile comes from the Phoenix generator, with
pinned Elixir, OTP and Debian versions. `mix.lock` pins the Elixir dependencies. Operating
system package updates can still change a later build, so keep a reviewed image tagged with
its commit rather than reusing one tag for different builds.

```sh
cp .env.example .env
chmod 600 .env
# Replace the values in .env, especially the secrets and PHX_HOST.
# Database password: openssl rand -hex 32
# SECRET_KEY_BASE: mise exec -- mix phx.gen.secret

docker compose build app
docker compose up -d db
docker compose run --rm app /app/bin/migrate
docker compose up -d app
docker compose logs -f app
```

The application port is bound to `127.0.0.1:4011` only, and PostgreSQL publishes no port.
With PostgreSQL 18 the data volume lives at `/var/lib/postgresql`. The scripts are mounted
read-only into the database container at `/ops`. `docker compose down` keeps the data volume;
`down -v` would delete it.

Compose reads `.env` itself. Native releases do not load that file automatically.
In Compose, `POSTGRES_PASSWORD` is also part of the database URL, so use a hex password for
this template. Changing the `POSTGRES_*` values does not change users or passwords of a
database that has already been initialized.

## HTTPS and the first account

Put an HTTPS reverse proxy in front of the internal HTTP port. It has to support WebSockets
and to set `X-Forwarded-Proto` itself. An example for Caddy on the host, with the domain
replaced:

```caddyfile
sikio.example.org {
    reverse_proxy 127.0.0.1:4011
}
```

With a native release, use the port chosen there. Expose only the proxy publicly. Register the
first account over the final HTTPS domain before opening the instance to anybody else, for
example while the proxy is temporarily restricted to your own address. The first account
claims the instance; everybody after it arrives on an invitation. For public operation, add
rate limiting for `/auth/*` at the proxy. The application limits those endpoints per peer
address as well, but a single instance behind a proxy sees the proxy.

## Backup and restore

The scripts use the usual `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` and
`PGPASSFILE`/`PGPASSWORD` variables. Never pass credentials as command arguments. Use
`pg_dump` and `pg_restore` from PostgreSQL 18. Restore only your own, trusted dumps. The
custom format makes a consistent database backup, and `pg_restore --single-transaction
--exit-on-error` makes the restore atomic. Reference:
[pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html),
[pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html).

```sh
mkdir -p backups
chmod 700 backups
# Set PGHOST/PGUSER/PGPASSFILE beforehand.
PGDATABASE=sikio scripts/backup "backups/sikio-$(date -u +%Y%m%dT%H%M%SZ).dump"

# Restore into a NEW database only, with no application running against it.
createdb sikio_restore_check
PGDATABASE=sikio_restore_check scripts/restore backups/YOUR_BACKUP.dump
```

Backup files are created with mode 0600 and published only after the dump and a format check
have succeeded. An existing file is never overwritten. Restore refuses a database that already
holds objects, and uses no `--clean`.

The same scripts inside the Compose database container, choosing a new archive name per backup:

```sh
docker compose exec -T db sh -c 'PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB" /ops/backup /tmp/sikio-backup.dump'
mkdir -p backups
chmod 700 backups
docker compose cp db:/tmp/sikio-backup.dump backups/sikio-backup.dump
chmod 600 backups/sikio-backup.dump
# Remove the temporary container file only after the copy has succeeded.
docker compose exec -T db rm /tmp/sikio-backup.dump

# A restore check in an additional database:
docker compose cp backups/sikio-backup.dump db:/tmp/sikio-restore.dump
docker compose exec -T db sh -c 'createdb -U "$POSTGRES_USER" sikio_restore_check'
docker compose exec -T db sh -c 'PGUSER="$POSTGRES_USER" PGDATABASE=sikio_restore_check /ops/restore /tmp/sikio-restore.dump'
```

To actually return to a backup, stop the application first, restore into a new database, check
the data, and only then point `DATABASE_URL` or the Compose `POSTGRES_DB` at it. Keep the old
data volume. These scripts stay available for manual backups. For daily encrypted backups,
retention, weekly restore checks and an optional external copy, see the
[backup runner and its schedule](backups.md). Timers and an external target are set up
explicitly on the target server.

## Updates and checks

Before an update: take a backup, review the new commit, and build a new release or image. For
an incompatible migration, stop the application, migrate, then start the new version. Use an
older application only if it supports the current schema, and do not roll migrations back as a
matter of course. Note the release or image version together with the time of the backup.

```sh
mise run check
mise run audit
mise run release
# Set PGHOST/PGPORT/PGUSER/PGPASSWORD for a local test server with CREATEDB rights:
mise exec -- elixir scripts/smoke_release.exs
```

The smoke test creates two randomly named databases and removes only those again. It checks
migration, repeated migration, backup, an actual restore, the refusal of a second restore, and
an HTTP start of the release on a free loopback port. It uses no existing database. It needs
Elixir 1.20 with OTP 29 and the PostgreSQL client tools.

A second smoke test covers the container images. It builds nothing itself, so build them first.
On Apple silicon, Apple's `container` runtime provides this; Davit ships and manages it:

```sh
container build --cpus 4 --memory 4G --progress plain -t sikio:container-smoke .
container build --cpus 4 --memory 4G --progress plain \
  -f deploy/Dockerfile.backup -t sikio-backup:container-smoke .
mise exec -- elixir scripts/smoke_containers.exs
```

That run creates its own internal network, a data volume and containers with random names. It
uses no existing database and no `.env` file. It checks migrations including a repeat, an
application start without root, the HTTP page and the built assets, a manual backup with mode
0600, a restore with a data comparison, and the refusal of a non-empty target database. It then
checks the backup container: encryption, a copy into a second local repository, retention,
restore checks and status. Test containers, their network, volume and temporary backups are
cleaned up even when a check fails. After a hard process kill, resources prefixed
`sikio-smoke-` can be left behind.

## What has been verified here

`mise run check` runs the ExUnit tests of the backup and restore scripts along with everything
else. `mise run release` builds the native release on this machine, macOS on ARM64, and
`scripts/smoke_release.exs` passes against a local PostgreSQL 18: migration, a repeated
migration, a backup with mode 0600, a real restore with the data compared, the refusal of a
second restore into the same database, and the release answering HTTP.

Both images were built from this checkout with Apple's `container` 1.3.1 and
`scripts/smoke_containers.exs` passes against them under Linux on ARM64: migrations including a
repeat, the release starting as a non-root user, the rendered page with its compiled assets, a
0600 backup, restore checks with the data compared, the refusal of a non-empty target, the
encrypted repositories, an application restart, and data surviving the database container being
recreated.

`scripts/smoke_backups.exs` passes too, against Restic 0.19.1; see [backups](backups.md).

Docker Compose was exercised on a separate Linux host with Docker 29.8.1 and Compose v5.5.1,
on x86_64, which is the only place amd64 has been covered. The stack built, the database came
up healthy, migrations ran and were idempotent on a second run, and the application answered
`/health` and `/setup` with its digested assets. The three things only Compose can show all
held: the application waited for the database to report healthy before starting, the port was
published on `127.0.0.1` alone and was not reachable on the host's address, and killing the
BEAM brought the container back under `unless-stopped`. `docker compose down` kept the volume
and the schema survived it.

No server has been set up, and nothing has been deployed publicly.
