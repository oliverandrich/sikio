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
| `SOURCE_URL` | Where this deployment offers its source; only needed for a modified Sikio |
| `TRUSTED_PROXIES` | Addresses that may forward a visitor's own; only needed for a proxy on another host |
| `ACCOUNT_IDENTITY` | `username` (the default) or `email`; anything else stops the boot. `email` requires the mail settings below |
| `MAIL_ENABLED` | `true` to deliver invitations; required by `ACCOUNT_IDENTITY=email` |
| `MAIL_FROM` | The address invitations come from |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` | Submission server; the port defaults to 587 |

`SOURCE_URL` is what the footer links to, which AGPL §13 asks an operator to offer. Leave it
unset to point at the upstream repository. A value that is not an absolute http or https URL
stops the boot, so a typo is refused by `bin/migrate` and `bin/server` rather than shown as a
link that goes nowhere.

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

The host manages process supervision and HTTPS. Caddy on the same machine is the
tested shape: it terminates TLS, proxies to `PORT` on the loopback, and forwards
the visitor's address. The proxy must support WebSockets and set
`X-Forwarded-Proto`; the public URL uses HTTPS on port 443. Expose only the proxy
publicly.

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
account asks for a code only the operator has. Issue one on the host, after
`bin/migrate` and once the public hostname is final:

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
