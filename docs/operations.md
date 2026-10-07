# Running a release

Sikio ships as a Mix release containing the application and its Erlang runtime, and as a
container image built from it; see [Run the image](#run-the-image).
Build for a compatible OS version, architecture and system libraries; a build on
one platform is not a portability guarantee for another. No Elixir, Mix or build
toolchain is needed on the target. Platform support must be verified separately.

## Choose a database

A release serves SQLite or PostgreSQL, chosen with `SIKIO_DATABASE` when it starts. SQLite is
the default and needs no database server: the data lives in one file on the host. PostgreSQL
suits an instance whose database runs elsewhere or is managed with other databases. Switching
later means moving the data, which Sikio does not do for you.

## Build and unpack

On the build machine, with the pinned tools installed:

```sh
mise run release
```

The release lands in `_build/prod/rel/sikio` and serves either database. Copy
the complete directory, or archive and unpack it on the target. Keep configuration and
persistent data outside that directory.

## Configure and start

For SQLite, choose an absolute path for the database file outside the release, in a
directory the service can write to. Migration creates the file. SQLite keeps a write-ahead
log beside it, `-wal` and `-shm`, which belong to the database. For PostgreSQL,
provide PostgreSQL 18 and an existing database with a dedicated owner. Migration creates the
`pg_trgm` extension for the library's search index; since PostgreSQL 13 the database's owner
may do that without further rights.

Export these variables in the environment used for both migration and startup:

| Variable | Meaning |
| --- | --- |
| `SIKIO_DATABASE` | `sqlite`, the default, or `postgres`; any other value stops the boot |
| `DATABASE_PATH` | SQLite: absolute path of the database file; a missing or relative path stops the boot |
| `DATABASE_URL` | PostgreSQL: `ecto://USER:URL_ENCODED_PASSWORD@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` on the build machine; keep permanently |
| `PHX_HOST` | Stable public hostname without scheme or port; a missing value stops the boot |
| `PORT` | Internal HTTP port, 4000 by default |
| `PHX_BIND_IP` | Address the HTTP listener binds to, all interfaces by default; `127.0.0.1` behind a proxy on the same host |
| `POOL_SIZE` | Database connections, 5 by default for SQLite and 10 for PostgreSQL |
| `ECTO_IPV6` | PostgreSQL: `true` to reach the database over IPv6 |
| `DNS_CLUSTER_QUERY` | DNS name that lists other nodes to cluster with; unset for a single node |
| `PICTURE_CACHE_DIR` | Absolute path for pictures fetched from publishers; outside the release, writable by the service |
| `SIKIO_MIGRATE_ON_START` | `false` to migrate by hand with `bin/migrate`; the release migrates on start by default |
| `LOG_LEVEL` | `info` (the default), `notice`, `warning`, `error`, `critical`, `alert` or `emergency`, in any case; anything else stops the boot |
| `FEED_POLL_MINUTES` | How often a source is asked at most, in whole minutes; 60 by default, at least 5 |
| `SOURCE_URL` | Where this deployment offers its source; only needed for a modified Sikio |
| `TRUSTED_PROXIES` | Addresses that may forward a visitor's own; only needed for a proxy on another host |
| `ACCOUNT_IDENTITY` | `username` (the default) or `email`; anything else stops the boot. `email` requires the mail settings below |
| `MAIL_ENABLED` | `true` to deliver invitations; required by `ACCOUNT_IDENTITY=email` |
| `MAIL_FROM` | The address invitations come from |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` | Submission server; the port defaults to 587 |

`PICTURE_CACHE_DIR` holds thumbnails and artwork that Sikio fetches on the reader's behalf.
Browsers load them from this host, so publishers never see who reads their feed. A missing or
relative path stops the boot. The directory is a cache: deleting it loses nothing, and a daily
job removes pictures nobody was served for thirty days.

`SOURCE_URL` is the source code link in the sidebar and the About dialog. AGPL §13 asks an
operator to offer it. Leave it unset to point at the upstream repository. A value that is not an absolute http or https URL
stops the boot, so a typo is refused by `bin/migrate` and `bin/server` rather than shown as a
link that goes nowhere.

The HTTP listener binds to `::` (all interfaces) unless `PHX_BIND_IP` names an address.
A value that is not an address stops the boot. `PORT` is configurable.
The release does not automatically load a `.env` file. Use a protected network
path for a remote PostgreSQL database; the current configuration does not enable database TLS.

SQLite runs as dj-lite sets it up for Django: a write-ahead log, `synchronous=NORMAL`, temporary
tables in memory, a 128 MiB memory map, transactions that take the write lock when they begin,
and a writer that waits up to five seconds for another. Every release sets them; PostgreSQL
ignores them.
From the unpacked release directory:

```sh
bin/server
```

The release migrates its database as it starts, before it serves anything. A
migration that fails stops the start and is logged; a supervisor that restarts the
service tries it again each time. Set `SIKIO_MIGRATE_ON_START=false`
to migrate by hand instead, with `bin/migrate` before `bin/server`. Repeating a
migration is safe once all are applied. Migration does not create a PostgreSQL
database. `bin/server` enables Phoenix; when using `bin/sikio start`, set
`PHX_SERVER=true`.

The host manages process supervision and HTTPS. Caddy on the same machine is the
tested shape: it terminates TLS, proxies to `PORT` on the loopback, and forwards
the visitor's address. The proxy must support WebSockets and set
`X-Forwarded-Proto`; the public URL uses HTTPS on port 443. Expose only the proxy
publicly; with Caddy on the same machine, `PHX_BIND_IP=127.0.0.1` keeps the plain port off
the network.

Making an invitation is limited too, but per signed-in account rather than per
address: 20 in a 24-hour window, configurable with the other budgets. The counter
lives in memory on the node that served the request, so several nodes each keep
their own and a cluster-wide quota needs a shared limit at the edge. An edge rule
keyed by address does not replace it: the budget exists for an account somebody else
is holding, and that account can arrive from anywhere.

Authentication limits count per visitor, taken from the forwarding header. That
header is believed only on a connection from a trusted proxy. The loopback is
trusted already, so a proxy on the same machine needs no configuration; one on
another host is named in `TRUSTED_PROXIES`, comma separated, one address per entry
rather than a range. An address that is not an address stops the boot rather than
being dropped quietly. Nothing forwarded is
believed on a connection from anywhere else, so an instance exposed directly still
counts the address it actually sees.

`GET /health` checks HTTP liveness, not database readiness.

## Logs

A release writes one JSON object per line to stdout, where systemd's journal or Docker collects
it. Each line has `time`, `severity`, `message` and `metadata`. The metadata holds only these
keys: `feed_id`, `feed_title`, `host`, `account_id`, `reason`, `worker`, `job_id`, `attempt` and
`request_id`.

| Severity | Events |
| --- | --- |
| `error` | Crashes, with their stack trace |
| `warning` | `feed refresh failed`, with the feed's id, title and host and why; `job failed`, with a reason cut to 200 characters |
| `info` | `instance claimed`, `invitation made`, `invitation accepted`, `signed in`, by account id; migrations as they run |

Sikio keeps no access log: no line names a visitor's address, a username, an item or a code. A
feed's address is left out too, since a private feed may carry a token in it. A proxy in front
logs access if wanted; Caddy does with a `log` directive in its site block. `LOG_LEVEL=warning`
leaves only what needs attention. `debug` is not offered: it would log sessions and query
parameters.

A crash is logged as an `error` with its stack trace. When a LiveView process crashes, the report
includes the message it was handling, which may hold what a member typed.

## Run under systemd

[sikio.service](sikio.service) is an example unit for a release on a Linux host. Sikio installs
none of this; it is one layout among others.

Each version is unpacked into a directory of its own, and a symlink names the current one:

```text
/opt/sikio/releases/0.1.0/    an unpacked release
/opt/sikio/current            -> releases/0.1.0
/etc/sikio/sikio.env          the environment, readable by root only
/var/lib/sikio/               the SQLite file and the picture cache, owned by the service
```

Create a system user without a login, then the environment file:

```sh
useradd --system --home-dir /var/lib/sikio --shell /usr/sbin/nologin sikio
install -d -m 0755 /etc/sikio
install -m 0600 /dev/null /etc/sikio/sikio.env
```

```sh
# /etc/sikio/sikio.env
SECRET_KEY_BASE=...
PHX_HOST=sikio.example.org
PHX_BIND_IP=127.0.0.1
DATABASE_PATH=/var/lib/sikio/sikio.db
PICTURE_CACHE_DIR=/var/lib/sikio/pictures
```

systemd reads the file as root before it starts the service, so it stays unreadable for the
service user. The unit creates `/var/lib/sikio` through `StateDirectory`. It keeps the rest of the
system read-only, which the release allows: it writes nothing into its own directory as it
starts. Install and start it:

```sh
cp sikio.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sikio
journalctl -u sikio -f
```

An update follows the order in [Updates and data protection](#updates-and-data-protection):

```sh
sqlite3 /var/lib/sikio/sikio.db ".backup /var/backups/sikio-$(date +%F).db"
mkdir /opt/sikio/releases/0.2.0
tar -xzf sikio-0.2.0-linux-arm64.tar.gz -C /opt/sikio/releases/0.2.0 --strip-components=1
ln -sfn releases/0.2.0 /opt/sikio/current
systemctl restart sikio
curl -fsS http://127.0.0.1:4000/health
```

The restart migrates the database. Keep the previous directory until the update is verified;
returning to it is described under [Migration rollback](#migration-rollback).

## Run the image

The image is `ghcr.io/oliverandrich/sikio`, for `linux/amd64` and `linux/arm64`. Each version
is tagged `X.Y.Z`, its minor line `X.Y` and `latest`. It runs the release above and takes the
same variables. It starts with `bin/server`, which migrates the database before it serves.

It keeps its data in the volume `/data`: the SQLite file at `/data/sikio.db` and the pictures in
`/data/pictures`. With SQLite only `SECRET_KEY_BASE` and `PHX_HOST` remain to set. For
PostgreSQL, set `SIKIO_DATABASE=postgres` and `DATABASE_URL`; `/data` then holds the pictures.
The image runs as `nobody`, so the volume must be writable for that user.

A proxy on the host reaches the container through the container network's gateway, not the
loopback. Name that gateway in `TRUSTED_PROXIES`, or every visitor counts as one address.
[compose.yaml](compose.yaml) is an example with SQLite, a fixed network and a port on the
loopback for the proxy.

Back up the volume, or the PostgreSQL database and the volume, before every update.

## Naming or addressing accounts

An account is called one of two things here, and the instance chooses which before anybody
registers.

By default it is a username, and an invitation is a link whoever made it passes on however they
like. Nothing is sent and no mail is configured.

`ACCOUNT_IDENTITY=email` makes it an address instead. The invitation is then addressed to that
address and delivered to it, which is also what proves the address belongs to whoever answers.
That requires the mail settings: `MAIL_ENABLED=true` and the `SMTP_*` variables beside it.
Submission is authenticated and the server's certificate is verified. An instance that asks for
addresses without being able to send any refuses to start and says so.

Choose once, before the first account. Turning an instance that already has accounts from names
to addresses would leave every identifier it holds failing the new format.

## Claim the instance

An instance answers on the network before anybody has claimed it, so the first
account asks for a code only the operator has. Issue one on the host, once the
release has started and migrated and the public hostname is final:

```sh
bin/setup-code
```

The code is printed once and nothing else keeps it; only its digest is stored.
Issuing another code makes the previous one worthless, which is how a lost one is
replaced. The command refuses to print anything for an instance that already has
an account.

Then open the final HTTPS host, enter the code, and register the first passkey.
Keep the recovery codes, which are shown once. Passkeys are bound to the domain
they were made on, so claiming over a temporary hostname leaves a passkey the
public one cannot use.

The code buys a proof that lasts ten minutes and is spent by the account it makes.
Somebody slower than that meets the code field again rather than a refusal after
the passkey dialogue.

## Updates and data protection

The operator manages database backups and OS-level backups, including runtime
configuration and secrets. For SQLite, copy a running database with `sqlite3 DATABASE_PATH
".backup BACKUP_PATH"` rather than copying the file, which may miss what the write-ahead log
still holds. For PostgreSQL, use `pg_dump`. Sikio has no backup or restore commands, retention
scheduler, remote backup service or self-updater.

For an update, back up the database first: the new release migrates it as it
starts. Then stop the old application and start the new release's `bin/server`
with the existing environment. Check `/health` and application access. Keep the old
release until the update is verified. Returning to it is safe only if it supports
the resulting database schema; replacing application files does not undo migrations.
To go back, stop the new release so a restart cannot migrate again, undo its migrations with
its rollback command, then start the old release.


## Migration rollback

For an explicitly reviewed rollback, replace the example version below with the
oldest migration version to undo (the boundary version is also rolled back):

```sh
bin/sikio eval 'Sikio.Release.rollback(Sikio.Repo, 20260918000000)'
```


## Background work

Oban runs on the application's own database, so no separate broker is needed. The `feeds`
queue refreshes each source when its next check has come. That is a tenth of its newest entry's
age after the last request, at least `FEED_POLL_MINUTES` and at most a day; a failed request is
tried again after `FEED_POLL_MINUTES`. A server's `Retry-After` and `Cache-Control: max-age`
can only lengthen that wait, up to the same day or `FEED_POLL_MINUTES` if longer. A feed's
`<ttl>` does the same after an answer with content; a `304` carries none. A server that names
its wait is not retried before it. Each next request is postponed by up to a tenth of its wait,
at most ten minutes, so feeds imported together do not stay in step. The scheduler looks every five minutes, so the requests
spread over the interval. `maintenance` runs
`Sikio.AuthCleanup` every 15 minutes, which expires sessions, abandoned challenges and
unaccepted invitations.
