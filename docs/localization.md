# Localization

The locale is set from the `Accept-Language` header on every HTTP request. The
fallback is `en`. The supported locales are `en` and `de` by default. Accounts
store no language preference.

A changed browser language applies from the next HTTP request or full page load.
A connected LiveView keeps its locale until then. The session carries the locale
of the latest HTTP request into the LiveView. It never overrides the header of a
new request.

The first supported base language in the header wins, in tag order. q-values are
ignored. Configure `:locales` on the application and `:default_locale` on its
Gettext backend. Add the `{Locale, :set}` hook to every new `live_session`, after
the account hook. `Locale.accept_locale/1` does not read the session, so it works
before the session is fetched.

For translation editing commands, see [Contributing](../CONTRIBUTING.md#translations).
