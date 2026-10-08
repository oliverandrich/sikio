# Run Sikio from a release under systemd

This guide installs a release tarball on a Linux host and runs it as a systemd service behind
Caddy. The last steps claim the instance. A release includes the Erlang runtime. The host needs
no Erlang or Elixir installation. [Operations](../operations.md) documents every setting.

## What you need

- Linux on x86_64 or arm64 with glibc 2.35 or newer, as on Ubuntu 22.04 or Debian 12. The
  releases are built on Ubuntu 22.04.
- systemd, `curl`, `sha256sum`, and `sqlite3` for backups.
- `libsctp1`. Without it the Erlang runtime prints an SCTP warning on every command.
- A domain name that resolves to the host, for example `sikio.example.org`. Passkeys are bound
  to the domain they are created on, so use the final domain from the start.
- Caddy on the same host, or another reverse proxy that terminates TLS and supports WebSockets.

## 1. Download and verify a release

Each GitHub release has one tarball per architecture and a `SHA256SUMS` file. Set the version
and your architecture, `x86_64` or `arm64`:

```sh
version=0.1.0
arch=x86_64
base=https://github.com/oliverandrich/sikio/releases/download/v$version
curl -fsSLO "$base/sikio-$version-linux-$arch.tar.gz"
curl -fsSLO "$base/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
```

## 2. Create the user and directories

Each version is unpacked into its own directory. A symlink points to the current one:

```text
/opt/sikio/releases/0.1.0/    an unpacked release
/opt/sikio/current            -> releases/0.1.0
/etc/sikio/sikio.env          the environment, readable by root only
/var/lib/sikio/               the SQLite file and the picture cache, owned by the service
```

```sh
sudo useradd --system --home-dir /var/lib/sikio --shell /usr/sbin/nologin sikio
sudo mkdir -p /opt/sikio/releases/$version
sudo tar -xzf sikio-$version-linux-$arch.tar.gz -C /opt/sikio/releases/$version --strip-components=1
sudo ln -sfn releases/$version /opt/sikio/current
```

The release directory stays owned by root. The service user has read access only.

## 3. Write the environment file

```sh
sudo install -d -m 0755 /etc/sikio
sudo install -m 0600 /dev/null /etc/sikio/sikio.env
sudoedit /etc/sikio/sikio.env
```

```sh
# /etc/sikio/sikio.env
SECRET_KEY_BASE=   # openssl rand -base64 48
PHX_HOST=sikio.example.org
PHX_BIND_IP=127.0.0.1
DATABASE_PATH=/var/lib/sikio/sikio.db
PICTURE_CACHE_DIR=/var/lib/sikio/pictures
```

`SECRET_KEY_BASE` signs sessions. Never change it after the first start. systemd reads the file
as root before it starts the service. The service user has no read access to it.
[Operations](../operations.md#configure-and-start) lists every setting, including PostgreSQL.
On a small host, these two lines in `sikio.env` lower memory use:

```sh
ERL_AFLAGS=+S 2:2
RELEASE_MODE=interactive
```

[Operations](../operations.md#small-installations) explains what they do.

## 4. Install the unit and start

[sikio.service](../sikio.service) runs `bin/server` as the user `sikio` and creates
`/var/lib/sikio`. `ProtectSystem=strict` makes the rest of the file system read-only for the
service.

```sh
sudo curl -fsSL -o /etc/systemd/system/sikio.service \
  https://raw.githubusercontent.com/oliverandrich/sikio/main/docs/sikio.service
sudo systemctl daemon-reload
sudo systemctl enable --now sikio
journalctl -u sikio -f
```

On the first start, the migration creates the SQLite database. The log line
`Running SikioWeb.Endpoint` means the server accepts requests. Check it from the host:

```sh
curl -fsS http://127.0.0.1:4000/health
```

## 5. Put Caddy in front

```caddyfile
sikio.example.org {
	reverse_proxy 127.0.0.1:4000
}
```

Caddy obtains the certificate and sends the client address in `X-Forwarded-For`. Sikio trusts
the loopback by default. Reload Caddy and open `https://sikio.example.org`.

## 6. Claim the instance

The first account requires a setup code. Issue it with the service user and environment:

```sh
sudo systemd-run --uid=sikio --gid=sikio -p EnvironmentFile=/etc/sikio/sikio.env \
  --pipe --wait /opt/sikio/current/bin/setup-code
```

The command prints the code once. Open your domain, enter the code, choose a username and
create a passkey. Save the recovery codes on the next page, which are shown only once. If the
code is lost, issue a new one. See [Operations](../operations.md#claim-the-instance) for details.

Further members join through invitations. Create them under Settings, then Invitations, in
the gear menu.

## 7. Back up

The `sqlite3` command `.backup` copies a running database consistently, including data in the WAL:

```sh
sudo -u sikio sqlite3 /var/lib/sikio/sikio.db ".backup /var/lib/sikio/backup-$(date +%F).db"
```

Move the copy off the host and keep `/etc/sikio/sikio.env` with it. With a different
`SECRET_KEY_BASE`, all existing sessions become invalid. With PostgreSQL, use `pg_dump` instead.

## 8. Update

Read the version's entry in the [changelog](../../CHANGELOG.md) first. Back up, then download
and verify the new version as in step 1. Then run:

```sh
sudo mkdir -p /opt/sikio/releases/$version
sudo tar -xzf sikio-$version-linux-$arch.tar.gz -C /opt/sikio/releases/$version --strip-components=1
sudo ln -sfn releases/$version /opt/sikio/current
sudo systemctl restart sikio
curl -fsS http://127.0.0.1:4000/health
```

The restart migrates the database. Keep the previous directory until the update is verified.
Switching the symlink back is not enough to downgrade. An older release does not revert a newer
release's migrations. Restore the backup, or roll back as in
[Operations](../operations.md#migration-rollback) before you start the older release.
