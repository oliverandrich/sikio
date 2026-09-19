# Localization

The application resolves the language from `Accept-Language` on every HTTP
request, falling back to `en`. Supported defaults are `en` and `de`. There is no
stored account preference. A changed browser language takes effect on the next
HTTP request/full page load; an already connected LiveView keeps its current
language until then. The session only transports the latest HTTP choice to
LiveView and never overrides a new request header.

Header parsing follows the first supported base language in tag order;
q-value weighting is not implemented. Configure `:locales` on the
application and `:default_locale` on its Gettext backend. New `live_session`
blocks should include the application's `{Locale, :set}` hook after account loading.
`Locale.accept_locale/1` also works before a session has been fetched.

For translation editing commands, see [Contributing](../CONTRIBUTING.md#translations).
