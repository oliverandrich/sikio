<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/logo-dark.svg">
    <img alt="Sikio" src="docs/images/logo.svg" height="56">
  </picture>
</h1>

**Your time. Your queue.**

![Sikio's inbox beside a video with its chapters](docs/images/screenshot.webp)

*Sikio* is Swahili for "ear" ([word origin](https://en.wiktionary.org/wiki/sikio)). Sikio is a
self-hosted media library for podcasts, YouTube and PeerTube. You choose what enters your lists
and mark what you have watched or heard.

## What it does

- Subscribes to podcasts, YouTube channels and PeerTube channels. One input field accepts a
  feed URL, a website, a channel or video URL, or an Apple Podcasts search term.
- Imports and exports subscriptions as OPML.
- Keeps an inbox of new items, a queue in your own order, and a history of heard items.
  With **Play on**, the queue plays the next item when one ends.
- Plays podcasts in its own audio player and videos in their official embeds. Playback continues
  while you navigate the library. Playback positions are saved, and chapters are shown.
- Follows every source through the public feed it publishes. Podcasts, YouTube channels and
  PeerTube channels all offer one. Sikio downloads no video or audio and needs no API key. A
  channel or video link is resolved to its feed once, when you subscribe.
- Hides a YouTube channel's Shorts unless you enable them for that subscription.
- Serves a small group on one instance. Accounts sign in with passkeys and join by invitation.

[Using Sikio](docs/usage.md) explains the library, playback and supported feeds.

## Install it

Sikio runs on Linux, x86_64 or arm64, with SQLite or PostgreSQL. Two guides cover installation
up to a claimed instance behind Caddy:

- [Run Sikio with Docker](docs/install/docker.md): the image `ghcr.io/oliverandrich/sikio` with
  Docker Compose.
- [Run Sikio from a release under systemd](docs/install/systemd.md): a release tarball from
  GitHub as a systemd service.

[Operations](docs/operations.md) documents every setting, logging, updates and backups.

## Develop it

You need [mise](https://mise.jdx.dev). The full check also needs PostgreSQL 18 and Chrome with a
matching chromedriver.

```sh
mise trust
mise install
mise run setup
mise run setup-code
mise dev
```

Open **http://localhost:4000**, enter the code that `mise run setup-code` printed, and create
your first passkey. [Contributing](CONTRIBUTING.md) covers setup, checks and the contribution
workflow.

## Documentation

- [Using Sikio](docs/usage.md): subscriptions, playback and supported feeds.
- [Run Sikio with Docker](docs/install/docker.md) and
  [from a release under systemd](docs/install/systemd.md).
- [Operations](docs/operations.md): settings, logs, accounts, updates and background work.
- [Authentication](docs/authentication.md): accounts, invitations and security.
- [Localization](docs/localization.md): language selection and translations.
- [Contributing](CONTRIBUTING.md): development setup, mise commands and tests.
- [Changelog](CHANGELOG.md): changes per version and the steps each update requires.

## License

Copyright (C) 2026 Oliver Andrich and contributors

Sikio is free software, licensed under the GNU Affero General Public License
version 3 or later (`AGPL-3.0-or-later`). See [LICENSE](LICENSE) for the full text.

Sikio is network-facing software, so AGPL §13 applies. A hosted instance must offer its source,
including modifications, to its users. The sidebar footer and the About dialog link to it.
[Operations](docs/operations.md) lists the setting for a modified version.
