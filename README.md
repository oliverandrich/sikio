# Sikio

**Your time. Your queue.**

*Sikio* is Swahili for "ear". A self-hosted media library for YouTube and podcasts: you decide
what lands in your list and what you have already watched or heard.
[Word origin](https://en.wiktionary.org/wiki/sikio).

## What it does

Phoenix LiveView, PostgreSQL and Ithibati passkeys with recovery codes and invitations. The
first visitor claims the instance; everybody after that arrives on an invitation link. There is
no administrator role and no mail delivery, so links are passed on by hand.

Under **Subscriptions** you can:

- Paste YouTube channel URLs, handles, video, Shorts and live URLs. Sikio resolves the channel
  behind them and shows its feed before you subscribe.
- Paste a podcast RSS feed or a podcast website. Several feeds found on one page are offered for
  choice, for example an MP3 and an Opus version of the same show.
- Search Apple Podcasts, or paste an Apple Podcasts link. A preview checks the actual RSS feed
  before subscribing.
- Manage your subscriptions, pause their polling and remove them.
- Import an OPML file with up to 50 unique sources and 1 MB, as a preview first. Existing
  subscriptions stay untouched and failures are reported per source. The export carries sources,
  not playback positions or polling settings. Format:
  [OPML 2.0](https://2005.opml.org/spec2.html).

Subscribing imports the current episodes. Oban refreshes active sources every 15 minutes, with
conditional HTTP requests and bounded retries. The library shows up to 100 matching items from
your sources, newest first. Filters by source, media type and status combine, and they live in
the URL, so a reload and the browser's back button keep them. New episodes, status changes and
subscriptions added or removed elsewhere appear without a reload.

Each source is stored once and shared; the subscriptions belong to individual accounts. A source
somebody paused can still be refreshed for other active subscribers. Removing a subscription
deletes no shared episodes.

**Play** opens the player for one item:

- Podcasts: native audio controls with pause, seek and speed from 0.75× to 2×. The player can be
  compacted without interrupting playback.
- YouTube: the official embed in privacy-enhanced mode, loaded only after a deliberate click.
- Your own state: new, in progress, or watched and heard. Marking is reversible, and marking
  something unwatched also resets its position.
- Positions are saved every five seconds, on pause, after seeking, and when the tab is hidden.
  Reaching the end completes the item; playing it again does not undo that.
- The visible player survives moving between the library, an item, the subscriptions and the
  invitations. One item plays per tab, and switching or closing waits for the last position to be
  saved. On a broken connection the switch waits until saving is possible again.
- A new player for the same item in another tab or on another device takes the session over. Old
  player messages and late events cannot overwrite a newer position. A lost connection pauses
  playback.

Progress survives feed updates and removing and re-adding a source. Marking by hand and removing
a subscription stop the affected player in other tabs immediately. A full reload, signing out or
closing the tab ends playback; pause briefly or close the player first so the last seconds are
saved.

Audio is loaded directly from the publisher, so available formats and seeking depend on the
browser and the media server. YouTube can refuse private, deleted or non-embeddable videos; the
player says so and links to YouTube. Only the embed and the API script send the page origin as a
referrer, because everything else is `no-referrer`.

URL discovery needs no personal API keys. Not every website publishes a discoverable feed; use
the direct RSS link then. Websites and feeds are capped at 8 MB, URLs at 2048 bytes, and website
discovery at five feed candidates. At most 500 episodes are taken per import. Supported are
podcast RSS with audio enclosures and YouTube Atom; general blog feeds are refused. The
application requests only public HTTP(S) addresses on ports 80 and 443, checks every redirect
target, and connects to the checked address while keeping the original TLS hostname.

## Running it locally

You need [mise](https://mise.jdx.dev), a running PostgreSQL 18, and Chrome with a matching
chromedriver for the browser tests.

```sh
mise trust
mise install
mise run setup
mise run dev
```

Open **http://localhost:4000** and register your first passkey. Save the recovery codes; they
are shown once. Under Invitations you can then create links. Invitations last seven days, are
bound to the username you choose, and can be used once.

Development and tests default to `postgres:postgres` on `localhost:5432`, with separate
`sikio_dev` and `sikio_test` databases. `PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT` override
the connection. Use passkeys over **localhost** locally and over HTTPS once published, and
register the first account before opening a new deployment to anybody else.

## Development

```sh
mise run check   # The full local gate
mise run test    # ExUnit, LiveView, browser and JavaScript tests
mise run format  # Formatting
mise run audit   # Dependency advisories and retired packages
mise run release # A production release for this OS and architecture
mise run beans   # The local backlog
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers configuration, the checks and the browser test setup.
[AGENTS.md](AGENTS.md) holds the project rules.

## Operations

Sikio runs as a standalone Elixir release or as a Docker image with PostgreSQL. `mise run
release` builds a native release; `Dockerfile` and `compose.yaml` build the container variant
from the same base. Backup and restore use the same scripts, and restore only ever writes into
an empty target database. The optional [backup runner](docs/backups.md) adds daily encryption,
retention, weekly restore checks and a configurable external copy.

Step by step, including HTTPS, updates and a restore check: [operations](docs/operations.md).
Both documents say plainly which parts have been verified in this repository and which have not.
Nothing has been deployed publicly yet.
