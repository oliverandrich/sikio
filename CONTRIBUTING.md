# Development

## Get started

Install **mise** and **PostgreSQL 18**, then prepare and start the application:

```sh
mise trust
mise install
mise run setup
mise run dev
```

Open **http://localhost:4000**. `mise run setup` explicitly creates, migrates and
seeds the development database, then builds assets.

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
Production uses `DATABASE_URL` and `SECRET_KEY_BASE`; see the release section below.

## Command reference

| Command | Purpose |
| --- | --- |
| `mise run check` | Workflow audit, compilation, format check, Credo, xref, Sobelow, assets, tests |
| `mise run test` | Tests with their test-database setup |
| `mise run format` | Explicit formatting |
| `mise run credo` | Compile then strict Credo |
| `mise run audit` | Dependency advisories and retired Hex packages |
| `mise run migrate` | Explicit development migrations |
| `mise run debugserver` | IEx Phoenix server |

Keep migration history unchanged. Credo scans source, tests and all migrations;
Jump inspects inline HEEx and files reached through embed_templates. ExSlop and
Jump rules are explicitly selected. Audit findings are separate from PR gates.
Tidewave runs only in development on loopback at /tidewave/mcp.
Tailwind/esbuild are Mix-managed; Node is unnecessary.
Use Lucide components directly, for example `<Lucideicons.chevron_down class="size-4" aria-hidden="true" />`.
Decorative icons are hidden from assistive technology; label icon-only buttons.
The `lucide_icons` dependency supplies SVG components without a Tailwind icon plugin. The UI helpers use the CSP's inline-script/style allowances.

Read AGENTS.md for TDD and commit review rules. Generated code belongs to this
application. Re-running the same starter/profile does nothing; it does not upgrade
or overwrite your edits. Review dependency updates through normal PRs.

## Locales and translations

Generated projects resolve the language from `Accept-Language` on every HTTP
request, falling back to `en`. Supported defaults are `en` and `de`. There is no
stored account preference. A changed browser language takes effect on the next
HTTP request/full page load; an already connected LiveView keeps its current
language until then. The session only transports the latest HTTP choice to
LiveView and never overrides a new request header.

Header parsing follows the first supported base language in tag order, as in
Chapisho; q-value weighting is not implemented. Configure `:locales` on the
application and `:default_locale` on its Gettext backend. New `live_session`
blocks should include the application's `{Locale, :set}` hook after account loading.
`Locale.accept_locale/1` also works before a session has been fetched.

With Ithibati, all auth/member screens, ceremony errors, clipboard messages and
validation errors have English/German support. English is the source language;
German catalogs live under `priv/gettext/de/LC_MESSAGES`. Use
`mix gettext.extract --merge` after adding `gettext` calls, then fill in the PO
translations. Clipboard messages are translated on the server, not duplicated in JS.

## Health, releases and migrations

`GET /health` is a public liveness endpoint returning `{"status":"ok"}`. It does
not query the database, set cookies, expose configuration or require authentication.
It proves the HTTP application can answer, not that every dependency is ready.

Build with the project's pinned Elixir/OTP versions on a system compatible with
the deployment target:

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The release is in `_build/prod/rel/sikio`. Set `DATABASE_URL`, `SECRET_KEY_BASE`,
`PHX_HOST` and `PORT` for the deployment. Run migration once as an explicit deploy
step, then start the application with `PHX_SERVER=true`:

```sh
bin/sikio eval 'Sikio.Release.migrate()'
PHX_SERVER=true bin/sikio start
```

The migration command starts the repo without the HTTP server. It is safe to run
again when all migrations are already applied. It does not create the database.
Provide a database and take backups through your deployment's normal workflow.
The application does not migrate automatically during boot.

For an explicitly reviewed rollback, replace the example version below with the
oldest migration version to undo (the boundary version is also rolled back):

```sh
bin/sikio eval 'Sikio.Release.rollback(Sikio.Repo, 20260918000000)'
```

No deployment service, container image or job scheduler is imposed by the starter.

## Local Beans tracking

Install Beans separately. Search unfinished tickets before creating work; update
progress and finish with a Summary of Changes. Run `beans check` after changes.
`.beans/` and `.beans.yml` are ignored and not backed up by Git pushes.

## Invitation-only authentication

Ithibati is pinned to 0.4.0. On an empty database the first visitor can claim the
instance with a username and passkey. Complete this on a trusted local/private
connection before exposing a new deployment. Later registrations require a valid
invitation; every authenticated member can create links on `/`. Links are
shown once, expire, and are accepted once. There is no administrator role or mail
delivery; share links through your chosen channel.

Sessions are revocable and cookies are encrypted because they temporarily carry
recovery codes. Recovery codes are displayed once after registration. Adapt the
account policy to the application.
`mix ithibati.doctor` is part of the test-environment gate after schema setup.

Browser tests are mandatory: install Chrome and a matching Chromedriver. On CI,
CHROMEWEBDRIVER points at the runner's driver directory. Locally configure a matching
`chromedriver` in ignored `mise.local.toml`, or set CHROMEWEBDRIVER. Check both
versions after browser updates. `mise run check` builds assets before browser tests;
for direct `mise run test`, build them with `mix assets.build` first. Tests start
an endpoint on port 4102; override PORT to isolate concurrent suites. Missing browser
infrastructure fails instead of silently skipping coverage.

The public auth screens are `/login` (passkey), `/recover` (recovery code), and
`/setup` (first account only). Signed-in visitors go to `/`. The project name and
auth appearance live in `Layouts.auth/1`; the one-time code screen includes a copy
button and a manual-copy fallback when clipboard permission is unavailable.

The member header in `Layouts.member/1` takes `current_account` and displays the
username menu. `/account/passkeys` supports enrollment, naming and removal; the
last passkey cannot be removed. `/account/recovery-codes` shows the unused count
and requires explicit confirmation before replacing every old code. New codes
use the same one-time display and copy flow as registration.

Passkey changes and code regeneration use controller requests with a freshly
validated session and CSRF protection. Enrollment binds the challenge to the
signed-in account and checks the account again when registration completes.
Adding a passkey or generating new recovery codes also requires a confirmation
with the current account's passkey or recovery code within the last five minutes.
Enrollment rechecks confirmation at both challenge creation and completion. All settings and feedback are translated into English
and German.

## Authentication limits and maintenance

`AuthRateLimit` allows 10 recovery requests and 120 other ceremony requests per
peer IP in a 60-second fixed window. Responses use HTTP 429, `Retry-After`, and a
translated ceremony message. Configure `:auth_rate_limits` on the application as
`[recovery: {10, 60}, ceremony: {120, 60}]` (positive counts and seconds).

The supervised in-memory counters are atomic and bounded to 10,000 keys per node;
a restart resets them. They use `conn.remote_ip` and do not trust arbitrary
`X-Forwarded-For` headers. Behind a reverse proxy, configure trusted proxy handling
in the deployment or enforce client-IP limits at the edge. Multiple nodes require
a shared edge limit for a cluster-wide budget. These defaults are not a distributed
rate-limit service.

The passkey settings page provides **Sign out on all devices**, including the
current session. Ithibati revokes stored sessions and broadcasts disconnects to
live sockets. Passkeys remain valid for future logins.

Run `mix auth.cleanup` explicitly in development or from your own scheduler.
For an already-running release, call:

```sh
bin/sikio rpc 'Sikio.AuthCleanup.run()'
```

It returns deletion counts for expired sessions, abandoned challenges and expired,
unaccepted invitations. Valid credentials, recovery codes and accepted invitations
are preserved. Nothing schedules this automatically: use Oban, cron or the hosting
platform if the concrete application needs scheduled maintenance.

Phoenix request logs filter passwords, secrets, tokens, recovery codes and WebAuthn
credentials through `:filter_parameters`. Preserve this filtering when adding logging.
