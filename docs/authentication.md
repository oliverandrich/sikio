# Authentication

Ithibati is pinned to 0.7.1. On an empty database the first account asks for a code
the operator issues on the host with `bin/setup-code`, and only then for a username
and passkey. The code is stored as a digest, buys a proof that lasts ten minutes,
and is spent by the account it makes; issuing another code voids the previous one
and any proof bought with it. `Sikio.Claim` refuses to start an instance configured
any other way. See [Operations](operations.md) for the order an operator follows.

Later registrations require a valid invitation; every authenticated member can
create links on `/invitations`. Links are shown once, expire, and are accepted
once. There is no administrator role.

The same page lists what is outstanding: for whom, by whom, when it was made and
when it runs out. Any member can take any of them back, and the link stops working
at once. Nobody can be removed from an instance once they are in, so this is the
only moment anybody has a say over who joins. An invitation written before the
inviter was recorded names nobody, and the list says so rather than inventing one.

An account is named or addressed, which `Sikio.Identity` answers from
`ACCOUNT_IDENTITY`. Named is the default: the link is shared through whatever
channel its sender likes. Addressed means the invitee's identifier is an email
address, the link is delivered to it, and that delivery is what proves the address.
Both schemas name `Sikio.Identity` for Ithibati's `:format` and `:format_message`
rather than carrying a literal, so the shape is asked for on every changeset while
the identifier field itself stays fixed when the schema compiles. An instance
that addresses accounts without a mail configuration does not start. A delivery
that fails is reported and the link stays shareable by hand. See
[Operations](operations.md) for the variables.

Sessions are revocable and cookies are encrypted because they temporarily carry
recovery codes. A session lasts sixty days from sign-in. Its cookie carries that age, so it
survives closing the browser. Recovery codes are displayed once after registration. Adapt the
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
message. Making an invitation allows 20 per signed-in account in a 24-hour window.
Configure `:auth_rate_limits` on the application as
`[recovery: {10, 60}, ceremony: {120, 60}, setup: {10, 60}, invite: {20, 86_400}]`
(positive counts and seconds). A group the configured list omits keeps its default.

The invitation budget is counted against the account, not the browser: a session, a
name or an address would each let the same person start over. It is spent before the
form is validated, so an attempt that fails for any other reason still costs one —
otherwise the budget is emptied by typing nonsense. A refusal writes no invitation,
sends nothing, and leaves a link already on screen where it is, because that link
exists nowhere else. A day rather than an hour, and 20 rather than the Ithibati
Starter's 10: what this guards against is not a burst but an account somebody else
is holding, spending the operator's mail credentials at a steady drip.

The supervised in-memory counters are atomic and bounded to 10,000 keys per node;
a restart resets them. They count per visitor address, which `SikioWeb.ClientIp`
resolves: behind a reverse proxy every request arrives from one socket, so the
address comes from the forwarding header instead. That header is believed only on a
connection from a trusted proxy, which is the loopback plus whatever
`TRUSTED_PROXIES` names. Exposed directly, nothing forwarded is believed and the
socket address stands. Multiple nodes require a shared edge limit for a cluster-wide
budget. That applies to the invitation budget too: node-local counters do not enforce
a quota across a cluster, and an edge rule keyed by address does not replace one keyed
by account. These defaults are not a distributed rate-limit service.

The passkey settings page provides **Sign out on all devices**, including the
current session. Ithibati revokes stored sessions and broadcasts disconnects to
live sockets. Passkeys remain valid for future logins.

Run `mix auth.cleanup` explicitly in development when you want it to happen now.
It runs in its own node, so it cannot disconnect a running server's LiveViews.
For an already-running release, call:

```sh
bin/sikio rpc 'Sikio.AuthCleanup.run()'
```

It returns deletion counts for expired sessions, abandoned challenges and expired,
unaccepted invitations. It disconnects the LiveViews of each expired session. Valid credentials, recovery codes and accepted invitations
are preserved. `Sikio.Accounts.Cleanup` runs it every fifteen minutes on Oban's
maintenance queue, so a deployed instance needs no cron entry of its own.

Phoenix request logs filter passwords, secrets, tokens, recovery codes and WebAuthn
credentials through `:filter_parameters`. Preserve this filtering when adding logging.
