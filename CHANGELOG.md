# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A version that asks something of the operator says so under **Upgrading**: a migration, a new
or changed setting, a step to take before or after the update. A release migrates its database
as it starts unless `SIKIO_MIGRATE_ON_START=false`; back up the database before every update.
Its own section becomes the version's release notes.

## [Unreleased]

### Upgrading

- A migration moves `playback_preferences` into a new `preferences` table, which adds the start
  page and the language. The release runs it on start.

### Added

- [Operations](docs/operations.md#storage) describes what Sikio stores and how to measure it.
  The README states that Sikio follows public feeds and downloads no media.

### Changed

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
