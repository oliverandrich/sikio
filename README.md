<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/logo-dark.svg">
    <img alt="Sikio" src="docs/images/logo.svg" height="56">
  </picture>
</h1>

**Your time. Your queue.**

![Sikio's inbox beside a video with its chapters](docs/images/screenshot.webp)

*Sikio* is Swahili for "ear". A self-hosted media library for YouTube and podcasts: you decide
what lands in your list and what you have already watched or heard.
[Word origin](https://en.wiktionary.org/wiki/sikio).

## What it does

- Follows podcasts, YouTube channels and PeerTube channels. One field takes a feed, a website,
  a channel or video link, or a search of Apple Podcasts. OPML imports and exports
  subscriptions.
- Keeps an inbox of what is new, a queue in an order of your own, and a history of what you
  heard. The queue plays on from one item to the next.
- Plays podcasts in its own player and videos in their embeds, keeps playing while you move
  through the library, saves where you stopped and marks a podcast's chapters.
- Leaves a YouTube channel's Shorts out unless you ask for them.
- Serves a small group on one instance: accounts sign in with passkeys and arrive on
  invitations.

[Using Sikio](docs/usage.md) explains the library, playback and supported feeds.

## Install it

Sikio runs on Linux, x86_64 or arm64, with SQLite or PostgreSQL. Two guides go from nothing to
a claimed instance behind Caddy:

- [Run Sikio with Docker](docs/install/docker.md): the image `ghcr.io/oliverandrich/sikio` with
  Docker Compose.
- [Run Sikio from a release under systemd](docs/install/systemd.md): a release tarball from
  GitHub as a systemd service.

[Operations](docs/operations.md) is the reference for every setting, the logs, updates and
backups.

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

Open **http://localhost:4000**, enter the code `mise run setup-code` printed, and create your
first passkey. [Contributing](CONTRIBUTING.md) explains the setup, the checks and how changes
are made.

## Documentation

- [Using Sikio](docs/usage.md): subscriptions, playback and supported feeds.
- [Run Sikio with Docker](docs/install/docker.md) and
  [from a release under systemd](docs/install/systemd.md).
- [Operations](docs/operations.md): settings, logs, accounts, updates and background work.
- [Authentication](docs/authentication.md): accounts, invitations and security.
- [Localization](docs/localization.md): language selection and translations.
- [Contributing](CONTRIBUTING.md): development setup, mise commands and tests.
- [Changelog](CHANGELOG.md): what changed in each version, and what an update asks for.

## License

Copyright (C) 2026 Oliver Andrich and contributors

Sikio is free software, licensed under the GNU Affero General Public License
version 3 or later (`AGPL-3.0-or-later`). See [LICENSE](LICENSE) for the full text.

Sikio is network-facing software, so AGPL §13 applies: any hosted instance must offer its
(modified) source to its users. The sidebar's foot and the About dialog carry that link.
[Operations](docs/operations.md) says what to set when you deploy a modified version.
