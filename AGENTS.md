# Sikio

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and checks.

## Workflow

- Implement only the requested work. Backlog items do not authorize additional
  features. Preserve existing tooling during ordinary feature work.
- Use TDD for behavior changes: write a focused test, confirm the intended failure,
  implement the smallest passing change, then refactor with tests green. Reproduce
  bugs with a regression test first. For new tests of existing behavior, verify the
  assertion with a temporary targeted fault and restore the code. Setup failures
  do not count as red. Documentation-only changes need no new tests; explain when
  a meaningful red phase cannot be demonstrated.
- Run `mise run check` after changes; format explicitly with `mise run format`.
  Run dependency audits separately with `mise run audit`. Report check results
  and any checks that could not run. Read CONTRIBUTING for project-specific gates.
- Before a requested commit, review for bugs, regressions, security issues and
  rule violations. Simplify unnecessary branches and duplication without expanding
  scope, and rerun affected checks after edits. For documentation, review wording,
  consistency and links.
- Use Conventional Commits (`type(scope): short description`) with a short body
  explaining why and what changed; omit the body for self-explanatory changes.
  Commit or push only when explicitly requested.
- Do not run unattended migrations, resets or measurements against development
  data. Use disposable databases for experiments; a reset requires explicit scope.

## Work tracking

When local Beans tracking is configured:

- Search unfinished work before creating a ticket. Read the matching ticket and
  its parent/dependencies. Track progress there; do not create parallel TODO files
  or backlog comments in source. Complete one task before starting unrelated work.
- Mark work completed only after its acceptance criteria and checks pass, and add
  a `Summary of Changes`. For scrapped work, add `Reasons for Scrapping`.
- `beans list --ready` omits some unfinished work. Use `mise run beans` where
  available, or `beans list --no-status completed --no-status scrapped`.
- Keep new `.beans/` files and `.beans.yml` local and ignored. Do not force-add them,
  add ignore exceptions or remove already tracked tickets without instruction.
  Archive only when requested. Git pushes do not back up ignored tickets.
- Keep Bean IDs in Beans, not application code, tests, assets or README.
  Run `beans check` before finishing tracked work.

## Documentation structure

Keep the same division in the starter and all applications:

- `README.md`: project overview, features, a short getting-started path and links.
- `CONTRIBUTING.md`: development setup, mise commands, tests and contribution workflow.
- `AGENTS.md`: authoritative instructions for coding agents and project-specific rules.
- `docs/`: actual application or library documentation: usage, configuration,
  operations, architecture and public extension interfaces.

Do not put agent instructions or a second contributor guide under `docs/`.
Keep detailed explanations in one place and link to them. Update links when moving
content. Preserve project-specific documentation; common structure does not imply
identical application features. Other agent entry points such as `CLAUDE.md` refer
to `AGENTS.md` and do not maintain another set of rules.

## Deployment scope

Ship two forms, each for SQLite and PostgreSQL, on Linux x86_64 and arm64: a
Docker image and a Mix release tarball with its runtime. Persistent application
data and secrets belong outside the release directory or image.

A release migrates its database on start unless `SIKIO_MIGRATE_ON_START=false`.
`bin/migrate` and the rollback command remain for explicit runs. Versions follow
SemVer; a migration or configuration change raises the minor version.

Database provisioning, process supervision, TLS, database dumps and OS-level
file backups are the operator's responsibility. The documentation may show an
example systemd unit and compose file; Sikio installs neither. An installer may
only download and verify a release, changing nothing outside its own directory.
Do not add self-updaters or application-owned backup/restore commands,
retention, remote copies or schedules unless explicitly requested. Database
migration rollback and restoring user content are application concerns, not
infrastructure backup automation. CI service containers are unaffected. Build
and test for specific OS versions and architectures before claiming support.

## Common commands

Use mise as the entry point; `mise TASK` and `mise run TASK` are equivalent.
For application repositories and generated templates, keep these commands aligned
with Ithibati Starter:

- `setup`: install dependencies, prepare the development database and build assets.
- `debugserver`: development server with IEx in `MIX_ENV=dev`.
- `dev`: foreground Phoenix server in `MIX_ENV=dev`, without tmux or an agent.
- `reset`: `mix ecto.reset` in `MIX_ENV=dev`; drops and recreates the development
  database, including migrations and seeds. Run only when explicitly requested.
- `migrate`: explicit development migrations.
- `release`: compile assets and build a production release for the build platform.
- In the unpacked release, `bin/server` migrates the database and starts the
  HTTP server; `bin/migrate` applies migrations on their own.

Application-specific asset builds and quality checks remain in Mix aliases.

Deployment-specific configuration belongs in `config/runtime.exs` and environment
variables, not compiled installation paths. Keep releases movable, and put writable
data outside the release using configurable absolute paths. `rel/overlays/bin`
contains application start and migration commands, not host provisioning.
The target is a Mix release on Linux behind Caddy, which terminates TLS and
forwards the visitor's address. Validate native libraries and OS/architecture
compatibility on the actual target. VM resource
settings must remain operator-configurable; do not promise memory usage or pin
shared-host tuning as a universal default without measurements.

## UI conventions

Use vanilla Tailwind utility classes for UI. Do not add DaisyUI or depend on its
component classes or theme tokens. CoreComponents and Layouts are owned by this app.

## Architecture

Business logic lives in `Sikio` contexts, the interface in `SikioWeb`. Every library,
subscription and playback function takes the account first and is scoped to it in the
query rather than filtered afterwards. Feed content is shared between accounts and must
never carry a watched or heard status.

Ithibati owns passkeys, recovery codes, sessions and the atomic acceptance of an
invitation. Use its public API only. `SikioWeb.Auth` is the handler and
`Ithibati.Web.Gate` supplies `current_account`; do not add a second authentication
system beside it. Every member may invite; there is no administrator role.

Migrations and schemas use `:utc_datetime_usec`. Never reset a database that holds
development data.

One build serves SQLite, the default, and PostgreSQL. `SIKIO_DATABASE` chooses one when the
application starts. `Sikio.Repo` hands every call to `Sikio.Repo.SQLite` or `Sikio.Repo.Postgres`;
call `Sikio.Repo`, never those two. Every query and migration runs on both, and `mise run check`
tests both; the browser features run on SQLite alone, since the interface behaves alike on both.
Write portable Ecto queries; where the databases differ, branch at runtime in one named place, as
`Sikio.Repo.for_update/1` does with `Sikio.Repo.postgres?/0`. Nothing reads the database with
`compile_env`.

`SikioWeb.PlayerDockLive` is the one exception to the layout rule. It is an
independently authenticated LiveView rendered in the root layout, outside the view that
navigation swaps, so a YouTube iframe is never moved and never reloads. Everything else
renders inside `<Layouts.member>`.

## The player's third parties

The content security policy names exactly three openings and each one is the player's:
`media-src` for audio from whichever server published a podcast, plus `frame-src` and one
`script-src` origin for the YouTube embed and its IFrame API. The referrer policy is
`no-referrer`, and only the embed and the API script opt back in per element. Extend none
of this without a reason written beside it.

The IFrame API is the only external script, and it loads only after somebody presses play.
Everything else is bundled through `assets/js/app.js`.

## Background work

Oban runs on the application's database with two queues. `feeds` refreshes sources, and
`maintenance` expires sessions, challenges and unaccepted invitations. A feed is polled
once regardless of how many accounts subscribe to it, and a queued refresh rechecks
whether anybody still wants it.

## Tests

Tests are `async: true` with their own sandbox. Never use fixed waits. LiveView tests go
through DOM ids and real form interactions.

No test may reach real DNS or the network: `config/test.exs` pins the resolver and routes
every feed request through `Req.Test`, so a test that forgets its stub fails instead of
asking a stranger's server.

The player's browser half is covered by node's own test runner over
`assets/js/*.test.mjs`, and by Wallaby features for what only a browser can show. A feature
starts signed in with `signed_in/2` unless signing in is what it tests. After changing
JavaScript or CSS, check it in a browser with freshly built assets.
