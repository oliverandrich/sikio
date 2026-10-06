# Contributing

## Get started

Install **mise**, then prepare and start the application. **PostgreSQL 18** is needed for
`mise run check`, `mise run test` and `mise run smoke`, which cover both databases:

```sh
mise trust
mise install
mise run setup
mise run setup-code
mise run dev
```

Open **http://localhost:4000** and enter the code `mise run setup-code` printed.
`mise run setup` explicitly creates, migrates and seeds the development database,
then builds assets. Every instance protects its first account with an operator's
code, development included, so `mise run reset` is followed by another
`mise run setup-code`.

## Configure the database

Sikio builds for SQLite or PostgreSQL, chosen with `SIKIO_DATABASE` when it is compiled. SQLite
is the default. Each database builds into its own directory, `_build/sqlite` or
`_build/postgres`, so switching never recompiles the other. The development and test databases
under SQLite are `tmp/sikio_dev.db` and `tmp/sikio_test.db`.

To develop against PostgreSQL, set the variable in the ignored `mise.local.toml` as a default,
so a value given on the command line still wins:

```toml
[env]
SIKIO_DATABASE = "{{ get_env(name='SIKIO_DATABASE', default='postgres') }}"
```

PostgreSQL defaults are `localhost:5432`, user `postgres`, password `postgres`.
Override them through the environment when needed:

```sh
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
```

Tests use a separate `sikio_test` database, optionally suffixed with
`MIX_TEST_PARTITION`. Never point tests at development or production data. Under SQLite the
tests take turns, because the database has one writer and each test holds a transaction.
Production uses `DATABASE_PATH` or `DATABASE_URL`, and `SECRET_KEY_BASE`; see
[Operations](docs/operations.md).

## Command reference

| Command | Purpose |
| --- | --- |
| `mise run check` | Workflow audit, compilation, format check, Credo, xref, Sobelow, assets, tests; the database-dependent ones for both databases |
| `mise run test` | Tests against SQLite and PostgreSQL, with their test-database setup |
| `mise run format` | Explicit formatting |
| `mise run credo` | Compile then strict Credo |
| `mise run audit` | Dependency advisories and retired Hex packages |
| `mise run migrate` | Explicit development migrations |
| `mise run setup-code` | Issue the code that claims the development instance, printed once |
| `mise run dev` | Start the development server in the foreground |
| `mise run reset` | Drop and recreate the development database, migrate and seed |
| `mise run debugserver` | IEx Phoenix server |
| `mise run release` | A production release for this OS and architecture, for `SIKIO_DATABASE` |
| `mise run smoke` | Build a release for each database and run it against a disposable one |
| `mise run icons` | Draw the app icons, favicon and README logo from the wordmark; needs Chrome |

`scripts/icons.py` outlines the wordmark from the project's IBM Plex Sans. Edit its geometry and
colours there, run the task and commit what it writes.

`mise run check` and `mise run test` also run the player's JavaScript tests through node's
own runner over `assets/js/*.test.mjs`. No npm package is installed for them.

Keep migration history unchanged. A migration may branch for the database it runs on, and a
branch added later must leave every existing database's schema as it was. Credo scans source, tests and all migrations;
Jump inspects inline HEEx and files reached through embed_templates. ExSlop and
Jump rules are explicitly selected. Audit findings are separate from PR gates.
Tailwind and esbuild are Mix-managed. Node is needed only to run the player's JavaScript
tests; no npm package is installed.
Use Lucide components directly, for example `<Lucideicons.chevron_down class="size-4" aria-hidden="true" />`.
Decorative icons are hidden from assistive technology; label icon-only buttons.
The `lucide_icons` dependency supplies SVG components without a Tailwind icon plugin. The UI helpers use the CSP's inline-script/style allowances.

`mise dev`, `mise reset`, `mise migrate` and `mise release` are the short forms
of `mise run …`. Development tasks explicitly use `MIX_ENV=dev`; release builds
use `prod`. `mise reset` deletes the development database and runs its migrations
and seeds again. It is an explicit local action, never part of startup or checks.

Oban tests use `testing: :manual`, so jobs run only when a test explicitly executes them.

## Browser tests

Browser tests are mandatory: install Chrome and a matching Chromedriver. On CI,
CHROMEWEBDRIVER points at the runner's driver directory. Locally configure a matching
`chromedriver` in ignored `mise.local.toml`, or set CHROMEWEBDRIVER. Check both
versions after browser updates. `mise run check` builds assets before browser tests;
for direct `mise run test`, build them with `mix assets.build` first. Tests start
an endpoint on port 4102; override PORT to isolate concurrent suites. Missing browser
infrastructure fails instead of silently skipping coverage.

`mix ithibati.doctor` is part of the test-environment gate after schema setup.

## Testing on a phone

Passkeys need HTTPS and a host name, so a phone reaches the development server through a
private tunnel. With Tailscale on the Mac and the phone:

```bash
tailscale serve --bg 4000
SIKIO_DEV_URL=https://<mac>.<tailnet>.ts.net mise run dev
```

SIKIO_DEV_URL names the endpoint's host, which passkeys are bound to. Passkeys made for
`localhost` do not work there; sign in with a recovery code and add one on the phone.

Do not expose the development server through a public tunnel. Its error pages show source code.

## Release verification

```sh
mise run check
# Set PGHOST/PGPORT/PGUSER/PGPASSWORD for a local test server with CREATEDB rights:
mise run smoke
```

`mise run smoke` builds a release for SQLite and one for PostgreSQL, and checks each. CI runs
it after `mise run check`.

The smoke test checks that the package contains no backup operations. It starts the
release on its own randomly named disposable database, which the release migrates as it
starts, checks the schema and serves HTTP on a free loopback port. It then repeats
`bin/migrate`, and on a second disposable database migrates by hand with
`SIKIO_MIGRATE_ON_START=false` before starting. It asks for a host outside
the `force_ssl` exclude list: plain HTTP must redirect, and `x-forwarded-proto: https`
must be served with HSTS. It removes only that database and a temporary directory afterward.
It needs the build machine's Elixir, the `sqlite3` client and the PostgreSQL client tools;
these test tools are not runtime dependencies of the application.

## Changelog

Record each user-visible change in `CHANGELOG.md` under **Unreleased**, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) sections. A change that asks
something of the operator also goes under **Upgrading**: a migration, a new or changed
setting, a step before or after the update. Such a change raises the minor version.

## Local Beans tracking

Install Beans separately. Search unfinished tickets before creating work; update
progress and finish with a Summary of Changes. Run `beans check` after changes.
`.beans/` and `.beans.yml` are ignored and not backed up by Git pushes.

## Translations

With Ithibati, all auth/member screens, ceremony errors, clipboard messages and
validation errors have English/German support. English is the source language;
German catalogs live under `priv/gettext/de/LC_MESSAGES`. Use
`mix gettext.extract --merge` after adding `gettext` calls, then fill in the PO
translations. Clipboard messages are translated on the server, not duplicated in JS.

## Making changes

Use focused regression tests for behavior changes and run `mise check` before
submitting. Follow the TDD and Conventional Commit rules in [AGENTS.md](AGENTS.md).

## License markers

Every file we wrote carries `SPDX-License-Identifier: AGPL-3.0-or-later` in its first lines,
in whatever comment its language uses. A file that leaves this repository on its own still
says what it is; the license file does not travel with it.

`.mise/tasks/license` checks this and `mise run check` runs it. The task answers to its own
rule. Third party code under `assets/vendor` is excluded, because marking somebody else's
file with our license would be a false claim.

## Further reading

- [Operations](docs/operations.md): configuration, releases and migrations.
- [Authentication](docs/authentication.md): accounts, invitations and security.
- [Localization](docs/localization.md): language selection and translations.
