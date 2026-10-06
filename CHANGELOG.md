# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A version that asks something of the operator says so under **Upgrading**: a migration, a new
or changed setting, a step to take before or after the update. A release migrates its database
as it starts unless `SIKIO_MIGRATE_ON_START=false`; back up the database before every update.
Its own section becomes the version's release notes.

## [Unreleased]

### Added

The first version. Sikio follows podcasts, YouTube channels and PeerTube channels for a small
group of people on one instance.

- One field on **Add** takes a feed, a website, a channel or video link, or a search of Apple
  Podcasts. OPML files import and export subscriptions.
- An inbox, a queue in an order of one's own, a history of what was heard, and all items, with
  search, sources and tags.
- A player that keeps playing while one moves through the library, saves the position, and
  marks a podcast's chapters on its seek bar. YouTube and PeerTube play in their own embeds.
- Feeds are asked at most every `FEED_POLL_MINUTES`, less often when they rarely publish, and
  as rarely as their servers ask.
- Accounts with passkeys and recovery codes. The first account claims the instance with an
  operator's code; everybody after it arrives on an invitation.
- A Mix release for SQLite or PostgreSQL that migrates its database as it starts.
- English and German.
