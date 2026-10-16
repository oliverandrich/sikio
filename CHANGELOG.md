# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A version that asks something of the operator says so under **Upgrading**: a migration, a new
or changed setting, a step to take before or after the update. A release migrates its database
as it starts unless `SIKIO_MIGRATE_ON_START=false`; back up the database before every update.
Its own section becomes the version's release notes.

## [Unreleased]

## [0.6.0] - 2026-10-16

### Upgrading

- One migration runs on start. It adds the table of favourites.
- The search on Add asks a PeerTube index. Search terms go from the server to Sepia Search,
  run by Framasoft. `PEERTUBE_SEARCH_URL` names another index with the same API, such as a
  self-hosted one or a PeerTube instance.

### Added

- Favourites. A star in an item's detail, or the key `s`, adds it to a list of its own. A
  favourite stays in the library after its source is unsubscribed.
- A share button beside the star hands an item's original page to the system's share sheet.
  Where the browser has none, it copies the link.
- The search on Add finds PeerTube channels and videos across instances, in two more tabs. A
  channel is subscribed through its feed. A video goes to the queue or the inbox on its own.

### Fixed

- A click on a PeerTube or Mediathek video plays or pauses it. Before playback, a click on its
  picture starts it.
- Many open tabs of one account survive a library change. The sidebar loads once for all of
  them, a page on another source or tag keeps its list, and list reloads wait for a free
  database connection instead of crashing the page.
- A feed host whose first address refuses the connection is reached through its next address.
- An open page's connection no longer keeps the memory of its first render. With many open tabs
  this lowers the server's memory use.
- Lists and the sidebar load only what they show. Show notes, search text and a feed's fetch
  details stay in the database until an item opens, so every open tab keeps less memory.
- A broadcaster page that does not answer holds a picture lookup on Add for at most five seconds,
  redirects included, instead of fifteen. The row then shows its fallback picture, and the page
  is asked again ten minutes later.
- Search results on Add have element ids of their own. They shared some with the sidebar, so the
  page could update the wrong element.

### Security

- Bandit 1.13.0 fixes EEF-CVE-2026-105659, where an HTTP/2 client could hold stream processes
  open, and EEF-CVE-2026-105660, where a request could set the host and port the app sees.
- Decimal 3.2.0 fixes EEF-CVE-2026-97853, an unbounded allocation in `Decimal.round/3`.

## [0.5.0] - 2026-10-11

### Upgrading

- Five migrations run on start. They add an entry's audio-only file, a feed's artwork check and
  the Mediathek as a kind of source. They then key stored Mediathek programmes by broadcaster
  page and title and merge their copies, and remove jobs of a retired picture worker.
- The merge of Mediathek copies cannot be rolled back. Back up the database before the update.
- `MEDIATHEK_URL` optionally names another MediathekViewWeb instance for the Mediathek search.
  The public instance is the default.
- The content security policy adds `connect-src https:` and `blob:` media, so hls.js can load
  PeerTube streams and broadcaster playlists. A proxy that sets its own policy needs the same.

### Added

- The TV Mediathek of the German public broadcasters, searched through MediathekViewWeb. A film
  is added on its own, a series is subscribed as a source.
- Programmes show the picture of their broadcaster's page. A series shows its broadcaster's
  icon where the broadcaster's site offers one.
- The add page sorts a search into four tabs: podcasts, episodes, TV series and TV videos. Each
  row offers Add to queue, Add to inbox and Subscribe. A pasted link to one item shows it the
  same way.
- Subscribing asks which present episodes to take, the newest, all or none, and where new
  episodes go.
- PeerTube videos play in Sikio's own player, with a switch to the audio-only file where the
  instance offers one.
- A fullscreen button for PeerTube and Mediathek videos. Fullscreen shows the browser's own
  controls.
- The history filters by day from a month calendar.
- A source's or tag's first list holds its unfinished items, and the sidebar counts them.
- A podcast without its own artwork takes its cover from Apple Podcasts.

### Changed

- A new subscription brings only the newest episode by default. The others wait in the source
  under All items.
- Subscribing again after an unsubscribe decides afresh about episodes archived unplayed.

### Fixed

- The player closes when an ended item has no successor.
- A PeerTube video asks its instance for the stream on every play, so a moved or re-transcoded
  video still plays.

## [0.4.0] - 2026-10-08

### Upgrading

- A migration adds the `saved_entries` table. The release runs it on start.

### Added

- A link to one YouTube video, PeerTube video or podcast episode can add that item alone,
  without subscribing to its source. It goes to the queue or the inbox.
- An item saved this way can be removed from its detail page.
- `/add?url=` opens the add page with the link filled in and looks it up.

## [0.3.1] - 2026-10-08

### Fixed

- A release serves the web app manifest, the favicon and the touch icon under their digested
  names. They answered 404, so browsers installed Sikio as an app without an icon.

### Changed

- All items shows no count in the sidebar and on the Library page. The list heading still
  shows its total.

## [0.3.0] - 2026-10-08

### Upgrading

- A migration adds the `hub_subscriptions` table. The release runs it on start.
- YouTube channels are subscribed at Google's hub. The reverse proxy must pass `/websub/`
  unchanged, which Caddy does. `SIKIO_WEBSUB=false` turns it off.

### Added

- New videos of YouTube channels arrive within minutes by WebSub, where Google's hub reaches the
  instance. The subscriptions page marks such channels as Live. They are also checked once a day.

## [0.2.0] - 2026-10-08

### Upgrading

- A migration moves `playback_preferences` into a new `preferences` table, which adds the start
  page and the language. The release runs it on start.

### Added

- A settings page in the gear menu. It holds the start page, the interface language and Play
  on, and it leads to passkeys, recovery codes and invitations. A chosen language overrides the
  browser's.
- The library opens on the chosen start page: the queue, the inbox or a tag. A deleted start
  tag falls back to the list chosen before it.
- [Operations](docs/operations.md#storage) describes what Sikio stores and how to measure it.
  The README states that Sikio follows public feeds and downloads no media.

### Changed

- Play on moved from the queue's header to the settings page.
- The gear menu holds the settings, the keyboard shortcuts, About Sikio and Sign out. Passkeys,
  recovery codes and invitations moved to the settings page.
- An item counts as heard in its last minute instead of at 90 %. A two-hour episode was marked
  heard twelve minutes before its end. Items under ten minutes still count at 90 %.
- An item opened by its address deep in a list loads with a batch above and below it. The
  list grows upwards as one scrolls. Before, every row above it loaded first. An item 2,000 rows
  down took half a second and sent 2.7 MiB of HTML. The queue still loads every row above.

### Fixed

- A source's dialog saves its settings and tags together, or neither.
- Invalid settings stay in the dialog with the error beside the field. Before, the dialog
  closed and reported the subscription as not found.

## [0.1.1] - 2026-10-08

### Added

- [Operations](docs/operations.md#small-installations) describes two settings that lower memory
  use on small installations: `ERL_AFLAGS="+S 2:2"` and `RELEASE_MODE=interactive`.

### Fixed

- The image installs `libsctp1`. Without it every command, `bin/setup-code` included, printed an
  SCTP warning. A host running the release tarball needs the package too; see
  [Run Sikio from a release under systemd](docs/install/systemd.md).

## [0.1.0] - 2026-10-07

### Added

The first version. Sikio follows podcasts, YouTube channels and PeerTube channels for a small
group of people on one instance.

- One field on **Add** takes a feed, a website, a channel or video link, or a search of Apple
  Podcasts. OPML files import and export subscriptions.
- An inbox, a queue in an order of one's own, a history of what was heard, and all items, with
  search, sources and tags.
- A player that keeps playing while one moves through the library, saves the position, and
  marks a podcast's chapters on its seek bar. YouTube and PeerTube play in their own embeds.
- A YouTube subscription leaves the channel's Shorts out unless its dialog asks for them.
- Feeds are asked at most every `FEED_POLL_MINUTES`, less often when they rarely publish, and
  as rarely as their servers ask.
- Accounts with passkeys and recovery codes. The first account claims the instance with an
  operator's code; everybody after it arrives on an invitation.
- A Mix release that serves SQLite or PostgreSQL, chosen with `SIKIO_DATABASE`, and migrates
  its database as it starts. The same as an image, `ghcr.io/oliverandrich/sikio`, for amd64 and
  arm64, with its data in `/data`.
- `TRUSTED_PROXIES` takes address ranges such as `172.20.0.0/16`, for a proxy in a container on
  a shared Docker network.
- Logs as JSON lines on stdout at `LOG_LEVEL`: failing feeds and jobs, and sign-ins and
  invitations by account id. No access log. The events Sikio logs carry no names, addresses or
  codes.
- English and German.
