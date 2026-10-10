# Operations

This is the reference for running Sikio: settings, logs, accounts, updates and background jobs.
For installation, follow one of the guides:

- [Run Sikio with Docker](install/docker.md): the image with Docker Compose, behind Caddy.
- [Run Sikio from a release under systemd](install/systemd.md): a release tarball as a service,
  behind Caddy.

Sikio ships as a Mix release for Linux x86_64 and arm64. The release includes the Erlang runtime.
A container image is built from the same release. The guides use the examples
[compose.yaml](compose.yaml) and [sikio.service](sikio.service).

## Choose a database

A release supports SQLite and PostgreSQL. `SIKIO_DATABASE` selects one at startup. SQLite is the
default and needs no database server. Its data is one file on the host. PostgreSQL fits a
database on another host or one managed alongside other databases. Sikio has no command to move
data from one database to the other.

## Build from source

For a platform without a published release, build on a machine with the target's OS and
architecture. A build for one platform is not guaranteed to run on another. With the pinned
tools installed, run:

```sh
mise run release
```

The release is written to `_build/prod/rel/sikio` and supports both databases. Copy the complete
directory to the target, or archive it and unpack it there. Keep configuration and persistent
data outside that directory.

## Configure and start

For SQLite, choose an absolute path for the database file outside the release. The service user
needs write access to its directory. The first migration creates the file. SQLite runs in WAL
mode and writes the `-wal` and `-shm` files beside the database. They are part of the database.
For PostgreSQL, provide PostgreSQL 18 and an existing database with a dedicated owner. A migration
creates the `pg_trgm` extension for the library's search index. Since PostgreSQL 13 the database
owner may create it without further privileges.

Set these environment variables for both migration and startup:

| Variable | Meaning |
| --- | --- |
| `SIKIO_DATABASE` | `sqlite`, the default, or `postgres`; any other value stops the boot |
| `DATABASE_PATH` | SQLite: absolute path of the database file; a missing or relative path stops the boot |
| `DATABASE_URL` | PostgreSQL: `ecto://USER:URL_ENCODED_PASSWORD@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` on the build machine; never change it |
| `PHX_HOST` | Public hostname without scheme or port; must not change; a missing value stops the boot |
| `PORT` | Internal HTTP port, 4000 by default |
| `PHX_BIND_IP` | Listen address, all interfaces by default; `127.0.0.1` with a reverse proxy on the same host |
| `POOL_SIZE` | Database connections, 5 by default for SQLite and 10 for PostgreSQL |
| `ECTO_IPV6` | PostgreSQL: `true` to connect to the database over IPv6 |
| `DNS_CLUSTER_QUERY` | DNS name that resolves to the other cluster nodes; unset for a single node |
| `PICTURE_CACHE_DIR` | Absolute path for cached publisher pictures; outside the release, writable by the service |
| `SIKIO_MIGRATE_ON_START` | `false` to migrate manually with `bin/migrate`; by default the release migrates on start |
| `SIKIO_WEBSUB` | `false` to subscribe no YouTube channel at Google's hub; see [Background work](#background-work) |
| `LOG_LEVEL` | `info` (the default), `notice`, `warning`, `error`, `critical`, `alert` or `emergency`, case-insensitive; any other value stops the boot |
| `FEED_POLL_MINUTES` | Minimum poll interval per feed, in whole minutes; 60 by default, at least 5 |
| `SOURCE_URL` | URL of this deployment's source code; only needed for a modified Sikio |
| `TRUSTED_PROXIES` | Addresses or ranges such as `172.20.0.0/16` whose `X-Forwarded-For` is trusted; only needed for a proxy outside the loopback |
| `ACCOUNT_IDENTITY` | `username` (the default) or `email`; any other value stops the boot. `email` requires the mail settings below |
| `MAIL_ENABLED` | `true` to send invitations by email; required by `ACCOUNT_IDENTITY=email` |
| `MAIL_FROM` | Sender address of invitation emails |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` | SMTP submission server; the port defaults to 587 |

`PICTURE_CACHE_DIR` holds thumbnails and artwork that Sikio downloads from publishers. Browsers
load these pictures from the Sikio host. Publishers do not receive the reader's address for
them. A missing or relative path stops the boot. The directory is a cache, and deleting it loses
no data. A daily job deletes pictures that were not served for thirty days.

`SOURCE_URL` sets the source code link in the sidebar and the About dialog. AGPL §13 requires a
deployment of a modified version to offer its source. If unset, the link points to the upstream
repository. A value that is not an absolute http or https URL stops the boot. `bin/migrate` and
`bin/server` both fail on it.

The HTTP listener binds to `::` (all interfaces) unless `PHX_BIND_IP` sets an address. A value
that is not an IP address stops the boot. `PORT` sets the port. The release does not load a
`.env` file. Database TLS is not enabled. Reach a remote PostgreSQL database over a protected
network path.

Every release configures SQLite with the dj-lite settings for Django. These are WAL mode,
`synchronous=NORMAL`, temporary tables in memory and a 128 MiB memory map. Transactions take the
write lock at `BEGIN`. A writer waits up to five seconds for the lock. PostgreSQL ignores these
settings.
From the unpacked release directory:

```sh
bin/server
```

The release migrates its database on start, before it accepts requests. A failed migration is
logged and stops the start. A supervisor that restarts the service retries the migration on each
start. To migrate manually, set `SIKIO_MIGRATE_ON_START=false` and run `bin/migrate` before
`bin/server`. Running `bin/migrate` again after all migrations are applied changes nothing.
Migrations do not create a PostgreSQL database. `bin/server` sets `PHX_SERVER=true`. With
`bin/sikio start`, set `PHX_SERVER=true` yourself.

Process supervision and TLS are the host's responsibility. The documented setup is Caddy on the
same host. Caddy terminates TLS, proxies to `PORT` on the loopback and forwards the client
address. Any reverse proxy must support WebSockets and set `X-Forwarded-Proto`. The public URL is
HTTPS on port 443. Expose only the proxy publicly. With Caddy on the same host,
`PHX_BIND_IP=127.0.0.1` keeps the HTTP port off the network.

Authentication requests are rate-limited per client address. Sikio reads the client address
from `X-Forwarded-For` only on a connection from a trusted proxy. IPv6 addresses are counted per
`/64` prefix. The loopback is always trusted, so a proxy on the same host needs no configuration.
List any other proxy in `TRUSTED_PROXIES`, comma-separated. An entry is an address or a CIDR
range. Use a range for a proxy container whose address changes when it is recreated, such as
the subnet of a shared Docker network. An entry that is neither stops the boot. On connections
from any other peer, `X-Forwarded-For` is ignored and the peer address is counted.

Creating invitations is also rate-limited, per account rather than per address. The limit is 20
in a 24-hour window. It is set in the application config `:auth_rate_limits`, not by an
environment variable. Each node keeps its counters in memory. With several nodes, each counts
separately, so a cluster-wide limit needs a rate limit at the reverse proxy. A proxy limit per
address does not replace the per-account limit. A compromised account can send requests from any
address.

`GET /health` checks HTTP liveness. It does not check the database.

## Storage

Sikio stores no audio or video. Browsers load podcast audio from the publisher's server and
PeerTube videos from their instance. YouTube videos play in the official embed. Sikio keeps two kinds of data: the database and the picture cache.

The database holds feeds, entries with their show notes, subscriptions and playback state. Each
poll reads at most 500 entries of a feed. Sikio keeps stored entries, so the database grows with
every new entry.

The picture cache holds the pictures of feeds and entries, such as artwork and video thumbnails.
Each picture is at most 2 MB. A daily job deletes pictures that were not served for thirty days.

One PostgreSQL instance with 16 feeds and 1,845 entries used 21 MB for its database and 54 MB
for its picture cache. These commands print the sizes:

```sh
du -sh "$PICTURE_CACHE_DIR"
du -sh "$DATABASE_PATH"*   # SQLite, with its WAL files
psql -d DATABASE -c "select pg_size_pretty(pg_database_size(current_database()))"
```

## Small installations

The release keeps the Erlang VM defaults. On a small instance, two environment variables lower
memory use. Both apply to the Docker image and the release tarball.

| Variable | Effect |
| --- | --- |
| `ERL_AFLAGS="+S 2:2"` | Starts two schedulers instead of one per CPU core |
| `RELEASE_MODE=interactive` | Loads each module on its first call instead of at boot |

A scheduler is an OS thread that runs Erlang processes. The memory allocators keep one instance
per scheduler. Each instance holds free memory it has not returned to the OS. Fewer schedulers
mean fewer instances and less of that reserve. Erlang code then runs on two cores at most.

By default a release loads every module of every dependency at boot. Many of them never run on a
given instance, such as the adapter of the unused database. The interactive mode loads only the
modules a request or job calls. The first call of a module waits for it to load. A module
missing from the release fails on its first call, not at boot.

One PostgreSQL instance on six cores dropped from 248 MiB to about 90 MiB with both settings.
Loaded code fell from 53 MiB to 24 MiB. Results depend on the host and on which features run.
Compare `docker stats` or the service's memory before and after. This command prints the
loaded code in bytes:

```sh
bin/sikio rpc 'IO.inspect(:erlang.memory(:code))'
```

## Logs

A release writes one JSON object per line to stdout. The systemd journal or Docker collects it.
Each line has `time`, `severity`, `message` and `metadata`. The metadata contains only these
keys: `feed_id`, `feed_title`, `host`, `account_id`, `reason`, `worker`, `job_id`, `attempt` and
`request_id`.

| Severity | Events |
| --- | --- |
| `error` | Crashes, with their stack trace |
| `warning` | `feed refresh failed`, with the feed's id, title and host and why; `job failed`, with a reason cut to 200 characters |
| `notice` | `websub subscription denied`, with the feed's id and the hub's reason |
| `info` | `instance claimed`, `invitation made`, `invitation accepted`, `signed in`, by account id; `websub subscription verified`, by feed id; migrations as they run |

Sikio writes no access log. The events in the table do not contain client addresses,
usernames, items or codes. Feed URLs are omitted, because a private feed URL may contain a token.
Messages and `reason` values are not filtered. Crash reports and stack traces may contain other
data. A reverse proxy can write an access log. In Caddy, add a `log` directive to the site
block. `LOG_LEVEL=warning` drops `notice` and `info` lines. `debug` is not supported, because it
logs sessions and query parameters.

A crash is logged at `error` with its stack trace. A LiveView crash report includes the message
the process was handling. That message may contain text a member typed.

## Naming or addressing accounts

An account identifier is either a username or an email address. Choose the mode before the
first account registers.

The default is a username. An invitation is a link that the inviter shares by any means. Sikio
sends no email, and no mail settings are needed.

`ACCOUNT_IDENTITY=email` makes the identifier an email address. Sikio then sends the invitation
to that address. Receiving the link confirms that the invitee controls the address. This mode
requires `MAIL_ENABLED=true` and the `SMTP_*` variables. With `MAIL_ENABLED=true`, a missing
`SMTP_HOST`, `MAIL_FROM`, `SMTP_USERNAME` or `SMTP_PASSWORD` stops the boot. SMTP authentication
is always used, and the server certificate is verified. Port 465 uses implicit TLS, every other
port STARTTLS. With `ACCOUNT_IDENTITY=email` and mail not enabled, the boot stops with an error.

Choose once, before the first account. After a switch from usernames to email addresses,
existing identifiers fail validation.

## Claim the instance

An instance is reachable on the network before it has an account. The first registration
therefore requires a setup code from the operator. Issue one on the host after the release has
started and migrated, and after the public hostname is final:

```sh
bin/setup-code
```

The command prints the code once. Only its digest is stored. Issuing a new code invalidates the
previous one, so a lost code is replaced by issuing another. If an account exists, the command
issues no code and exits with status 1.

Then open the final HTTPS host, enter the code and register the first passkey. Save the recovery
codes, which are shown once. Passkeys are bound to the domain they were created on. A passkey
created on a temporary hostname does not work on the public one.

A valid code stores a setup proof in the session. The proof expires after ten minutes and is
consumed by the first account. A setup page loaded after the proof expires shows the code field
again.

## Updates and data protection

Database backups and OS-level backups are the operator's responsibility. They include runtime
configuration and secrets. For SQLite, copy a running database with `sqlite3 DATABASE_PATH
".backup BACKUP_PATH"`. A plain file copy may miss data still in the WAL file. For PostgreSQL,
use `pg_dump`. Sikio has no backup or restore commands, retention scheduler, remote backup
service or self-updater.

Back up the database before an update, because the new release migrates it on start. Then stop
the old release and start the new release's `bin/server` with the existing environment. Check
`/health` and sign in. Keep the old release until the update is verified. The old release only
works if it supports the migrated schema. Replacing release files does not revert migrations.
To go back, stop the new release so a restart cannot migrate again. Revert its migrations with
its rollback command, then start the old release.


## Migration rollback

For a reviewed rollback, replace the example version below with the oldest migration version to
revert. That version is reverted as well:

```sh
bin/sikio eval 'Sikio.Release.rollback(Sikio.Repo, 20260918000000)'
```


## Background work

Oban runs on the application database, so no separate message broker is needed. The `feeds`
queue refreshes each feed when its next check is due. The interval is a tenth of the newest
entry's age, at least `FEED_POLL_MINUTES` and at most one day. After a failed request, the next
check is after `FEED_POLL_MINUTES`. A `Cache-Control: max-age` header can only lengthen the
interval. So can `Retry-After` on a `429` or `503` response, and a feed's `<ttl>` on a `200`
response. A `304` response has no `<ttl>`. The lengthened interval is capped at one day, or at
`FEED_POLL_MINUTES` if that is longer. A feed with a server-requested wait is not retried before
it ends. Each next check gets a random delay of up to a tenth of its interval, at most ten
minutes. Feeds imported together therefore do not stay synchronized. The scheduler runs every
five minutes. The `maintenance` queue runs `Sikio.AuthCleanup` every 15 minutes. It deletes
expired sessions, expired challenges and unaccepted invitations that have expired.

### YouTube channels by WebSub

Google's hub at `pubsubhubbub.appspot.com` announces new videos of YouTube channels. It needs no
API key and no Google account. Once an hour, the `maintenance` queue subscribes each followed
YouTube channel at the hub. The callback is `https://PHX_HOST/websub/<token>`, with an unguessable
token per channel. The hub verifies the callback with a GET. Only a verified subscription is
active, so an instance the hub cannot reach keeps polling as before.

A push must carry a valid `X-Hub-Signature`. It brings the channel's next check forward, and the
scheduler then reads the feed as usual. A channel with an active subscription is also checked
once a day. Until a pushed video appears in the feed, its channel is checked every
`FEED_POLL_MINUTES`. Subscriptions are renewed at four fifths of their lease. A channel nobody
follows loses its subscription, and later pushes for it get a `410` response.

The reverse proxy must pass `/websub/` with its query string and body unchanged. Caddy's
`reverse_proxy` does. Google learns the callback URL and the channels the instance follows. The
instance already fetches these channels' feeds from YouTube. `SIKIO_WEBSUB=false` turns the
subscriptions off. PeerTube offers no hub, and podcasts are not covered, so both keep polling.
