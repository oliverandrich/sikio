# Authentication

Ithibati is pinned to 0.7.1. On an empty database, `/setup` first asks for a setup code. The
operator issues it on the host with `bin/setup-code`. Then it asks for a username and a passkey.
Only the code's digest is stored. A valid code yields a session authorization for ten minutes.
Creating the first account consumes the code. Issuing a new code invalidates the previous code
and its authorizations. `Sikio.Claim` stops the boot for any other `initial_claim` setting. See
[Operations](operations.md) for the operator's steps.

Later registrations require a valid invitation. Every signed-in member can create invitation
links on `/invitations`. A link is shown once, expires, and can be accepted once. There is no
administrator role.

The same page lists pending invitations with invitee, inviter, creation time and expiry. Any
member can withdraw any pending invitation, and its link stops working immediately. Sikio cannot
remove an account. Withdrawing an invitation is therefore the only control over who joins.
Invitations created before the inviter was recorded show no inviter, and the list states that.

The account identifier is a username or an email address. `Sikio.Identity` reads the mode from
`ACCOUNT_IDENTITY`, and the default is username. In username mode, the inviter shares the link
by any channel. In email mode, the invitee's identifier is an email address. The link is mailed
to that address, and accepting it proves control of the address. Both schemas pass
`Sikio.Identity` to Ithibati's `:format` and `:format_message` options instead of literals.
Ithibati calls them on every changeset, so the format follows the runtime mode. The identifier
field itself is fixed at compile time. An instance in email mode without mail configuration
stops at boot. A failed delivery shows an error, and the link can still be shared by hand. See
[Operations](operations.md) for the environment variables.

Sessions are revocable. The session cookie is encrypted, because it carries new recovery codes
until they are displayed. A session lasts sixty days from sign-in. The cookie's `max_age`
matches that lifetime, so the session persists after the browser closes. Recovery codes are
displayed once after registration.

The public auth pages are `/login` (passkey), `/recover` (recovery code) and `/setup` (first
account only). `/setup` posts the operator's code to `/setup/code` before it asks for a
username. Signed-in users are redirected to `/`. `Layouts.auth/1` holds the project name and
the layout of the auth pages. The recovery-code page has a copy button. If the clipboard write
fails, the page asks you to select and copy the codes manually.

The member header in `Layouts.member/1` takes `current_account` and shows the username menu.
`/account/passkeys` supports adding, renaming and removing passkeys. The last passkey cannot be
removed. `/account/recovery-codes` shows the number of unused codes. Replacing all codes
requires an explicit confirmation. New codes use the same one-time page and copy button as
registration.

Renaming and removing passkeys and regenerating codes are controller requests. Each request
validates the session and checks the CSRF token. Adding a passkey binds the challenge to the
signed-in account. The account is checked again when registration completes. Adding a passkey
or generating new recovery codes also requires a reauthentication within the last five minutes.
The reauthentication uses a passkey or recovery code of the current account. Adding a passkey
checks it both when the challenge is created and when registration completes. All settings
pages and messages are available in English and German.

## Authentication limits and maintenance
`AuthRateLimit` allows 10 recovery requests and 120 other ceremony requests per client
address in a 60-second fixed window. IPv6 addresses count per `/64` prefix. Exceeded requests
get HTTP 429 with `Retry-After`, and the page shows a translated message. Exchanging a setup
code allows 10 attempts per client address in a 60-second window. A rate-limited exchange redirects
to `/setup` with `Retry-After` and a message naming the wait. Creating invitations allows 20
per signed-in account in a 24-hour window. Configure `:auth_rate_limits` on the application as
`[recovery: {10, 60}, ceremony: {120, 60}, setup: {10, 60}, invite: {20, 86_400}]`
(positive counts and seconds). A group missing from the configured list keeps its default.

The invitation limit counts per account, not per browser. Counting per session, username or
address would let one account reset its count. The limit is checked before the form is
validated, so invalid submissions also count. Otherwise invalid input would bypass the limit. A
refused attempt creates no invitation and sends no mail. A link already on screen stays visible,
because it is stored nowhere else. The limit is 20 per day, while Ithibati Starter uses 10. The
limit targets a compromised account that sends mail through the operator's SMTP account at a
steady rate. A burst is not the threat it addresses.

The counters are in memory, in a supervised process, and are atomic per node. Each limit group
holds at most 10,000 keys per node. A restart resets them. `SikioWeb.ClientIp` resolves the
client address. Behind a reverse proxy, every socket peer is the proxy. The address then comes
from the `X-Forwarded-For` header. Sikio reads the header only from a trusted proxy: loopback
addresses and the entries of `TRUSTED_PROXIES`. For any other peer, the socket peer
address counts. Multiple nodes need a rate limit at the edge for a cluster-wide budget. This
also applies to the invitation limit. Node-local counters do not enforce a cluster-wide quota.
An edge rule keyed by address does not replace a limit keyed by account. These counters are not a
distributed rate-limit service.

The passkey settings page has **Sign out on all devices**, which includes the current session.
Ithibati revokes the stored sessions and disconnects their LiveView sockets. Passkeys remain
valid for later sign-ins.

In development, run `mix auth.cleanup` to clean up immediately. It runs in a separate node, so
it cannot disconnect the LiveViews of a running server. For a running release, call:

```sh
bin/sikio rpc 'Sikio.AuthCleanup.run()'
```

It returns deletion counts for expired sessions, expired challenges and expired, unaccepted
invitations. It disconnects the LiveViews of each expired session. Valid credentials, recovery
codes and accepted invitations remain. `Sikio.Accounts.Cleanup` runs it every fifteen minutes on
Oban's `maintenance` queue, so a deployment needs no cron entry.

Phoenix request logs filter parameters whose names contain `password`, `secret`, `token`, `code`
or `credential`. The setting is `:filter_parameters`. This covers recovery codes and WebAuthn
credentials. Keep this filtering when you add logging.
