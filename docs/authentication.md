# Authentication

Ithibati is pinned to 0.5.0. On an empty database the first account asks for a code
the operator issues on the host with `bin/setup-code`, and only then for a username
and passkey. The code is stored as a digest, buys a proof that lasts ten minutes,
and is spent by the account it makes; issuing another code voids the previous one
and any proof bought with it. `Sikio.Claim` refuses to start an instance configured
any other way. See [Operations](operations.md) for the order an operator follows.

Later registrations require a valid invitation; every authenticated member can
create links on `/`. Links are shown once, expire, and are accepted once. There is
no administrator role or mail delivery; share links through your chosen channel.

Sessions are revocable and cookies are encrypted because they temporarily carry
recovery codes. Recovery codes are displayed once after registration. Adapt the
account policy to the application.

The public auth screens are `/login` (passkey), `/recover` (recovery code), and
`/setup` (first account only), which asks for the operator's code before it asks
for a name and posts it to `/setup/code`. Signed-in visitors go to `/`. The project name and
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
peer IP in a 60-second fixed window. Exchanging a setup code allows 10 attempts in
the same window. Responses use HTTP 429, `Retry-After`, and a translated ceremony
message. Configure `:auth_rate_limits` on the application as
`[recovery: {10, 60}, ceremony: {120, 60}, setup: {10, 60}]` (positive counts and
seconds). A group the configured list omits keeps its default.

The supervised in-memory counters are atomic and bounded to 10,000 keys per node;
a restart resets them. They use `conn.remote_ip` and do not trust arbitrary
`X-Forwarded-For` headers. Behind a reverse proxy, configure trusted proxy handling
in the deployment or enforce client-IP limits at the edge. Multiple nodes require
a shared edge limit for a cluster-wide budget. These defaults are not a distributed
rate-limit service.

The passkey settings page provides **Sign out on all devices**, including the
current session. Ithibati revokes stored sessions and broadcasts disconnects to
live sockets. Passkeys remain valid for future logins.

Run `mix auth.cleanup` explicitly in development when you want it to happen now.
For an already-running release, call:

```sh
bin/sikio rpc 'Sikio.AuthCleanup.run()'
```

It returns deletion counts for expired sessions, abandoned challenges and expired,
unaccepted invitations. Valid credentials, recovery codes and accepted invitations
are preserved. `Sikio.Accounts.Cleanup` runs it every fifteen minutes on Oban's
maintenance queue, so a deployed instance needs no cron entry of its own.

Phoenix request logs filter passwords, secrets, tokens, recovery codes and WebAuthn
credentials through `:filter_parameters`. Preserve this filtering when adding logging.
