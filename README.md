# Sikio

**Your time. Your queue.**

*Sikio* is Swahili for "ear". A self-hosted media library for YouTube and podcasts: you decide
what lands in your list and what you have already watched or heard.
[Word origin](https://en.wiktionary.org/wiki/sikio).

## What it does

- Follow YouTube channels and podcasts, discover feeds and import/export OPML.
- Keep a personal queue with filters and live updates as new episodes arrive.
- Play podcasts and YouTube videos while navigating, with saved playback progress.
- Share an instance through invitation-only accounts secured by passkeys.

See [Using Sikio](docs/usage.md) for subscription, playback and feed limits.

## Running it locally

You need [mise](https://mise.jdx.dev), a running PostgreSQL 18, and Chrome with a matching
chromedriver for the browser tests.

```sh
mise trust
mise install
mise run setup
mise run setup-code
mise dev
```

Open **http://localhost:4000**, enter the code the previous command printed, and register your
first passkey. Save the recovery codes; they are shown once. Under Invitations in the account
menu you can then create links. Invitations last seven days, are bound to the username you choose, and can be
used once, and each member may make twenty a day. After `mise run reset` the database is
unclaimed again, so issue another code.

Development and tests default to `postgres:postgres` on `localhost:5432`, with separate
`sikio_dev` and `sikio_test` databases. `PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT` override
the connection. Use passkeys over **localhost** locally and over HTTPS once published.

## Documentation

- [Using Sikio](docs/usage.md): subscriptions, playback and supported feeds.
- [Contributing](CONTRIBUTING.md): development setup, mise commands and tests.
- [Operations](docs/operations.md): configuration, releases and migrations.
- [Authentication](docs/authentication.md): accounts, invitations and security.
- [Localization](docs/localization.md): language selection and translations.

## License

Copyright (C) 2026 Oliver Andrich and contributors

Sikio is free software, licensed under the GNU Affero General Public License
version 3 or later (`AGPL-3.0-or-later`). See [LICENSE](LICENSE) for the full text.

Sikio is network-facing software, so AGPL §13 applies: any hosted instance must offer its
(modified) source to its users. The footer carries that link. [Operations](docs/operations.md)
says what to set when you deploy a modified version.
