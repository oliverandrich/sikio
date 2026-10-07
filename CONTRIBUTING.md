# Contributing

## Get started

Install **mise**, then set up and start the application. `mise run check`, `mise run test` and
`mise run smoke` test both databases and need **PostgreSQL 18**:

```sh
mise trust
mise install
mise run setup
mise run setup-code
mise run dev
```

Open **http://localhost:4000** and enter the code from `mise run setup-code`.
`mise run setup` creates, migrates and seeds the development database, then builds assets.
Every instance requires a setup code for the first account, including development.
After `mise run reset`, run `mise run setup-code` again.

## Configure the database

One build supports SQLite and PostgreSQL. `SIKIO_DATABASE` selects one at startup. SQLite is
the default. Switching does not require a recompile. The SQLite development and test databases
are `tmp/sikio_dev.db` and `tmp/sikio_test.db`.

To develop against PostgreSQL, set a default in the ignored `mise.local.toml`. A value set on
the command line still takes precedence:

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

Tests use a separate `sikio_test` database, optionally suffixed with `MIX_TEST_PARTITION`.
Never point tests at development or production data. Under SQLite the tests run with
`max_cases: 1`. SQLite allows one writer, and each test holds a write transaction.
Production uses `DATABASE_PATH` or `DATABASE_URL`, and `SECRET_KEY_BASE`. See
[Operations](docs/operations.md).

## Command reference

| Command | Purpose |
| --- | --- |
| `mise run check` | Workflow audit, compilation, format check, Credo, xref, Sobelow, assets, tests; the database-dependent ones for both databases, the browser features on SQLite |
| `mise run check:lint`, `check:sqlite`, `check:postgres` | The three parts of `mise run check`, which CI runs as separate jobs |
| `mise run test` | Tests against SQLite and PostgreSQL, with their test-database setup |
| `mise run format` | Explicit formatting |
| `mise run credo` | Compile then strict Credo |
| `mise run audit` | Dependency advisories and retired Hex packages |
| `mise run migrate` | Explicit development migrations |
| `mise run setup-code` | Issue the code that claims the development instance, printed once |
| `mise run dev` | Start the development server in the foreground |
| `mise run reset` | Drop and recreate the development database, migrate and seed |
| `mise run debugserver` | IEx Phoenix server |
| `mise run release` | A production release for this OS and architecture, for both databases |
| `mise run smoke` | Build one release and run it against a disposable database of each kind |
| `mise run icons` | Draw the app icons, favicon and README logo from the wordmark; needs Chrome |

`scripts/icons.py` converts the wordmark in IBM Plex Sans to outlines. Edit geometry and colours
there, run the task and commit the generated files.

`mise run check` and `mise run test` also run the player's JavaScript tests in
`assets/js/*.test.mjs` with the node test runner. No npm package is installed for them.

Do not change existing migrations. A migration may branch on the database adapter. A branch
added later must leave the schema of every existing database unchanged. Credo scans source,
tests and all migrations. Jump inspects inline HEEx and files loaded through `embed_templates`.
ExSlop and Jump rules are enabled one by one. Audit findings do not block pull requests.
Tailwind and esbuild are managed by Mix. Node is needed only for the player's JavaScript tests.
No npm package is installed.
Use Lucide components directly, for example `<Lucideicons.chevron_down class="size-4" aria-hidden="true" />`.
Hide decorative icons from assistive technology with `aria-hidden="true"`. Label icon-only buttons.
The `lucide_icons` dependency provides SVG components without a Tailwind icon plugin.
The UI helpers rely on `'unsafe-inline'` for scripts and styles in the CSP.

`mise dev`, `mise reset`, `mise migrate` and `mise release` are short forms of `mise run …`.
Development tasks set `MIX_ENV=dev`. Release builds use `prod`. `mise reset` drops the
development database, then runs migrations and seeds. Run it only by hand. No startup task or
check runs it.

Oban tests use `testing: :manual`. Jobs run only when a test executes them.

## Browser tests

Browser tests are mandatory. Install Chrome and a matching Chromedriver. On CI,
CHROMEWEBDRIVER is the runner's driver directory. Locally, set a matching `chromedriver` in the
ignored `mise.local.toml`, or set CHROMEWEBDRIVER. Check both versions after browser updates.
`mise run check` builds assets before the browser tests. Before a direct `mise run test`, run
`mix assets.build`. Tests start an endpoint on port 4102. Set PORT to run suites concurrently.
A missing Chrome or Chromedriver fails the run. The browser tests are not skipped. They run
against SQLite only. `SIKIO_DATABASE=postgres mix test --include feature` runs them against
PostgreSQL.

`mix ithibati.doctor` runs in the test environment after the schema is migrated.

## Testing on a phone

Passkeys require HTTPS and a host name. A phone therefore connects to the development server
through a private tunnel. With Tailscale on the Mac and the phone:

```bash
tailscale serve --bg 4000
SIKIO_DEV_URL=https://<mac>.<tailnet>.ts.net mise run dev
```

SIKIO_DEV_URL sets the endpoint host. Passkeys are bound to that host. Passkeys created for
`localhost` do not work there. Sign in with a recovery code and add a passkey on the phone.

Do not expose the development server through a public tunnel. Its error pages show source code.

## Release verification

```sh
mise run check
# Set PGHOST/PGPORT/PGUSER/PGPASSWORD for a local test server with CREATEDB rights:
mise run smoke
```

`mise run smoke` builds one release and tests it with SQLite and with PostgreSQL. CI runs it as
a separate job.

The smoke test checks that the release has no `ops` directory for backup operations. It starts
the release on a disposable database with a random name. The release migrates it on start. The
test checks that the table `ithibati_setup_codes` exists. It requests the landing page over HTTP
on a free loopback port. It then runs `bin/migrate` again. On a second disposable database it
sets `SIKIO_MIGRATE_ON_START=false` and runs `bin/migrate` before the server starts. It sends
requests with a host outside the `force_ssl` exclude list. Plain HTTP must redirect to HTTPS.
A request with `x-forwarded-proto: https` must get a response with HSTS. Afterwards it deletes
only those databases and their temporary directories. It needs Elixir on the build machine, the
`sqlite3` client and the PostgreSQL client tools. These are test tools, not runtime dependencies.

The `Dockerfile` builds the image from source, as `mise run release` builds the tarball. Build it
with `docker build -t sikio .`. On a Mac, Apple's `container build -t sikio .` builds natively
for arm64. `scripts/smoke_image.sh IMAGE` starts the image with SQLite and with PostgreSQL. It
needs Docker with host networking and PG* settings for a server with CREATEDB. The release
workflow provides both on both architectures.

## Changelog

Record each user-visible change in `CHANGELOG.md` under **Unreleased**, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) sections. A change that requires
operator action also goes under **Upgrading**. Examples are a migration, a new or changed
setting, or a manual step before or after the update. Such a change raises the minor version.

## Cutting a version

1. Move the **Unreleased** entries in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD`.
2. Set the same version in `mix.exs` and commit both as `chore(release): X.Y.Z`.
3. Tag it with `git tag -a vX.Y.Z -m vX.Y.Z` and push `main` and the tag.

The tag triggers `.github/workflows/release.yml`. The workflow runs the CI checks on the tagged
commit. It builds a release for Linux x86_64 and arm64 on Ubuntu 22.04. It smoke-tests each
release with both databases. If all jobs pass, it publishes the releases with `SHA256SUMS` and the
changelog section as release notes. A manual run from the Actions tab builds and tests the
version in `mix.exs` and publishes nothing.

## Local Beans tracking

Install Beans separately. Search unfinished tickets before creating new ones. Record progress
in the ticket and finish with a Summary of Changes. Run `beans check` after changes.
`.beans/` and `.beans.yml` are ignored by Git, so a push does not back them up.

## Translations

Auth and member screens, ceremony errors, clipboard messages and validation errors are
translated into English and German. English is the source language. German catalogs are in
`priv/gettext/de/LC_MESSAGES`. Run `mix gettext.extract --merge` after adding `gettext` calls,
then fill in the PO translations. Clipboard messages are translated on the server, not in JS.

## Making changes

Add focused regression tests for behavior changes. Run `mise check` before submitting.
Follow the TDD and Conventional Commit rules in [AGENTS.md](AGENTS.md).

## License markers

Every source file of the project has `SPDX-License-Identifier: AGPL-3.0-or-later` in its first
five lines, in the comment syntax of its language. A file copied out of the repository keeps its
license statement without the license file.

`.mise/tasks/license` checks the files under the paths it lists, and `mise run check` runs it.
The task file carries the marker too. Third-party code under `assets/vendor` is excluded,
because it is under its own license.

## Further reading

- [Operations](docs/operations.md): configuration, releases and migrations.
- [Authentication](docs/authentication.md): accounts, invitations and security.
- [Localization](docs/localization.md): language selection and translations.
