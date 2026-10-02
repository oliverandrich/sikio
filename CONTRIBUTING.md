# Contributing

## Get started

Install **mise** and **PostgreSQL 18**, then prepare and start the application:

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

Local defaults are `localhost:5432`, user `postgres`, password `postgres`.
Override them through the environment when needed:

```sh
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
```

Tests use a separate `sikio_test` database, optionally suffixed with
`MIX_TEST_PARTITION`. Never point tests at development or production data.
Production uses `DATABASE_URL` and `SECRET_KEY_BASE`; see [Operations](docs/operations.md).

## Command reference

| Command | Purpose |
| --- | --- |
| `mise run check` | Workflow audit, compilation, format check, Credo, xref, Sobelow, assets, tests |
| `mise run test` | Tests with their test-database setup |
| `mise run format` | Explicit formatting |
| `mise run credo` | Compile then strict Credo |
| `mise run audit` | Dependency advisories and retired Hex packages |
| `mise run migrate` | Explicit development migrations |
| `mise run setup-code` | Issue the code that claims the development instance, printed once |
| `mise run dev` | Start the development server in the foreground |
| `mise run reset` | Drop and recreate the development database, migrate and seed |
| `mise run debugserver` | IEx Phoenix server |
| `mise run release` | A production release for this OS and architecture |
| `mise run smoke` | Build the release and run it against a disposable database |

`mise run check` and `mise run test` also run the player's JavaScript tests through node's
own runner over `assets/js/*.test.mjs`. No npm package is installed for them.

Keep migration history unchanged. Credo scans source, tests and all migrations;
Jump inspects inline HEEx and files reached through embed_templates. ExSlop and
Jump rules are explicitly selected. Audit findings are separate from PR gates.
Tidewave runs only in development on loopback at /tidewave/mcp.
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

## Release verification

```sh
mise run check
# Set PGHOST/PGPORT/PGUSER/PGPASSWORD for a local test server with CREATEDB rights:
mise run smoke
```

`mise run smoke` builds the release first. CI runs it after `mise run check`.

The smoke test checks that the package contains no backup operations, applies
migrations twice to its own randomly named disposable database, checks the schema,
and starts the release over HTTP on a free loopback port. It asks for a host outside
the `force_ssl` exclude list: plain HTTP must redirect, and `x-forwarded-proto: https`
must be served with HSTS. It removes only that database and a temporary picture
directory afterward. It needs the build machine's Elixir and PostgreSQL client tools;
these test tools are not runtime dependencies of the application.

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
