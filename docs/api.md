# Extension API

The browser extension talks to Sikio through API v1 under `/api/v1`. Requests and responses
are JSON. The extension and Sikio release apart, so the path carries the version. A change that
breaks a client gets a new version.

## Connecting

The extension gets its token through the sign-in described in
[Authentication](authentication.md#browser-extensions):

1. It opens `/extension/connect` with `redirect_uri`, `state`, `code_challenge` (S256) and
   `client` through `identity.launchWebAuthFlow`.
2. Sikio redirects to `redirect_uri` with `code` and `state`, or with `error=access_denied` or
   `error=invalid_request`.
3. It exchanges the code:

```http
POST /api/v1/token
{"code": "...", "code_verifier": "...", "redirect_uri": "..."}
```

The answer is `{"token": "..."}`. A code serves once and for a minute. Any failure answers 400
with `{"error": "invalid_grant"}`.

## Requests

Every other request carries the token:

```http
Authorization: Bearer <token>
```

The scheme is case-insensitive. A missing, unknown or disconnected token answers 401 with
`{"error": "invalid_token"}` and `WWW-Authenticate: Bearer`. An account may send 120 requests a
minute. A client address may send 120 token exchanges and requests without a valid token a
minute. More answer 429 with `{"error": "rate_limited"}` and `Retry-After` in seconds.
`lookup`, subscribing and adding read the page within 30 seconds; a page that takes longer
counts as one without a source or item. The extension calls Sikio from its own
context with a host permission, so Sikio sends no CORS headers.

### `GET /api/v1/subscriptions`

The account's sources with their identifiers. To check the sources of a page, use
[`match`](#post-apiv1subscriptionsmatch) instead:

```json
{"subscriptions": [{"feed_url": "...", "aliases": [], "kind": "youtube", "title": "...",
  "page_url": "...", "channel_id": "UC..."}]}
```

`kind` is `podcast`, `youtube`, `peertube` or `mediathek`. `channel_id` is set for YouTube
only. `aliases` lists other URLs the feed was fetched at. A new feed may be stored at the URL
its `atom:link rel="self"` names, while a page links another one.

### `POST /api/v1/subscriptions/match`

Which of a page's sources the account subscribes to. Send the feed URLs and YouTube channel ids
the extension detected on a page, never the page URL. Sikio reads no page for this.

```json
{"feed_urls": ["https://..."], "channel_ids": ["UC..."]}
```

```json
{"feed_urls": ["https://..."], "channel_ids": []}
```

The answer lists the sent values the account subscribes to, as they were sent. A feed URL
matches a subscribed feed's `feed_url` or one of its `aliases`. The comparison ignores the
scheme, the host's case, a default port, a trailing slash, an empty query and a fragment. Both
lists are required and hold at most 50 strings each. Anything else answers 400 with
`{"error": "invalid_request"}`. Each call counts against the account's 120 requests a minute,
so a client keeps the answer for a page until the page or a subscription changes.

### `POST /api/v1/lookup`

What a page offers and what the account has of it. Send it only for a page the extension
detected, so Sikio does not learn about other pages.

```json
{"url": "https://..."}
```

```json
{"sources": [{"feed_url": "...", "kind": "podcast", "title": "...", "icon_url": "...",
  "subscribed": false}],
 "item": {"title": "...", "source": "...", "place": null}}
```

`item` is null for a page that is no single episode or video. `place` names the list that holds
the item: `queue`, `inbox`, `heard` or `all`, and null while the account lacks it. A page with
nothing to add, or one that cannot be read in time, answers `{"sources": [], "item": null}`.

### `POST /api/v1/subscriptions`

Subscribes to a source from `lookup`:

```json
{"feed_url": "..."}
```

The answer is 201 with `{"subscription": {...}}`, shaped like an entry of `GET subscriptions`.
Subscribing again keeps the subscription and answers 200. An alias of a feed subscribes to
that feed, and the answer names its `feed_url`. A `feed_url` that names no feed answers 404;
Sikio never subscribes to another feed instead.

### `POST /api/v1/items`

Adds the page's episode or video to the inbox or the queue:

```json
{"url": "https://...", "at": "queue"}
```

The answer is 201 with `{"item": {"title": "...", "place": "queue"}}`.

## Errors

| Status | `error` | Meaning |
|---|---|---|
| 400 | `invalid_request` | A field is missing or has another value. |
| 400 | `invalid_grant` | The code cannot be exchanged. |
| 401 | `invalid_token` | The token is missing, unknown or disconnected. |
| 403 | `platform_off` | An administrator switched the source's platform off. |
| 404 | `not_found` | The page has no source or item to add. |
| 429 | `rate_limited` | Wait for `Retry-After` seconds. |
| 500 | `server_error` | Sikio could not save the subscription or the item. |
