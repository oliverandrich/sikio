# Running a release

Sikio ships as a Mix release containing the application and its Erlang runtime.
Build for a compatible OS version, architecture and system libraries; a build on
one platform is not a portability guarantee for another. No Elixir, Mix or build
toolchain is needed on the target. Platform support must be verified separately.

## Build and unpack

On the build machine, with the pinned tools installed:

```sh
mise run release
```

Copy the complete `_build/prod/rel/sikio` directory, or archive and unpack it on
the target. Keep configuration and persistent data outside that directory.

## Configure and start

Provide PostgreSQL 18 and an existing database with a dedicated owner. Export
these variables in the environment used for both migration and startup:

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | `ecto://USER:URL_ENCODED_PASSWORD@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` on the build machine; keep permanently |
| `PHX_HOST` | Stable public hostname without scheme or port |
| `PORT` | Internal HTTP port, 4000 by default |
| `POOL_SIZE` | Database connections, 10 by default |

The HTTP listener currently binds to `::` (all interfaces); `PORT` is configurable.
The release does not automatically load a `.env` file. Use a protected network
path for a remote database; the current configuration does not enable database TLS.
From the unpacked release directory:

```sh
bin/migrate
bin/server
```

Migration does not create the database or start the HTTP server. Repeating it is
safe once all migrations are applied. Startup never migrates automatically.
`bin/server` enables Phoenix; when using `bin/sikio start`, set `PHX_SERVER=true`.

The host or hosting provider manages process supervision and HTTPS. The reverse
proxy must support WebSockets and set `X-Forwarded-Proto`; the public URL uses
HTTPS on port 443. Expose only the proxy publicly. Register the first account on
the final HTTPS domain while access is restricted to you. Passkeys are bound to
that domain. Configure edge rate limits for `/auth/*` as needed: the application's
peer-address limits see the proxy when requests are proxied.

`GET /health` checks HTTP liveness, not database readiness.

## Updates and data protection

The operator manages PostgreSQL dumps and OS-level backups, including runtime
configuration and secrets. Sikio has no backup or restore commands, retention
scheduler, remote backup service or self-updater.

For an update, prepare a compatible new release and a database backup, stop the
old application, run the new release's `bin/migrate` with the existing environment,
then start its `bin/server`. Check `/health` and application access. Keep the old
release until the update is verified. Returning to it is safe only if it supports
the resulting database schema; replacing application files does not undo migrations.


## Migration rollback

For an explicitly reviewed rollback, replace the example version below with the
oldest migration version to undo (the boundary version is also rolled back):

```sh
bin/sikio eval 'Sikio.Release.rollback(Sikio.Repo, 20260918000000)'
```


## Background work

Oban runs on the application's own database, so no separate broker is needed. The `feeds`
queue refreshes sources every 15 minutes and `maintenance` runs `Sikio.AuthCleanup`, which
expires sessions, abandoned challenges and unaccepted invitations.
