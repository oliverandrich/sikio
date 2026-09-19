# Project instructions

Read CONTRIBUTING.md. Use test-driven development: reproduce intended failures before
implementation, then refactor with tests green. For tests of existing behavior,
verify the assertion with a temporary targeted fault and restore it. Setup failures
are not a red phase; explain any limitations. Documentation needs no new tests.

Run `mise run check`; use `mise run format` explicitly. Run audits separately.
Use Conventional Commits (`type(scope): summary`) with a short reason/result body,
except self-explanatory changes. Before committing, review for bugs, regressions,
security and rule violations; simplify unnecessary branches/duplication and rerun
checks. Commit and push only when asked. Project tools need no personal skills.

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
`assets/js/*.test.mjs`, and by Wallaby features for what only a browser can show. After
changing JavaScript or CSS, check it in a browser with freshly built assets.

## Deployment scope

Ship the application as a Mix release with its runtime: unpack, configure, run.
Keep explicit database migration commands and runtime configuration. Persistent
application data and secrets belong outside the release directory.

Database provisioning, process supervision, TLS, database dumps and OS-level
file backups are the operator's responsibility. Do not add Dockerfiles, Compose
stacks, deployment installers, self-updaters, or application-owned backup/restore
commands, retention, remote copies or schedules unless explicitly requested.
Database migration rollback and restoring user content are application concerns,
not infrastructure backup automation. CI service containers are unaffected.
Build and test for specific OS versions and architectures before claiming support.
