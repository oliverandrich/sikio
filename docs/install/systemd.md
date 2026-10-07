# Run Sikio from a release under systemd

This guide installs a release tarball on a Linux host, runs it as a systemd service behind
Caddy, and claims the instance. A release carries its own Erlang runtime; nothing else of
Elixir is needed on the host. [Operations](../operations.md) is the reference for every setting.

## What you need

- Linux on x86_64 or arm64 with glibc 2.35 or newer, as on Ubuntu 22.04 or Debian 12. The
  releases are built on Ubuntu 22.04.
- systemd, `curl`, `sha256sum`, and `sqlite3` for backups.
- A domain name pointing at the host, for example `sikio.example.org`. Passkeys are bound to
  the name they are made on, so choose the final one now.
- Caddy on the same host, or another proxy that terminates TLS and supports WebSockets.

## 1. Download and verify a release

Each release on GitHub has a tarball per architecture and a `SHA256SUMS`. Set the version and
your architecture, `x86_64` or `arm64`:

```sh
version=0.1.0
arch=x86_64
base=https://github.com/oliverandrich/sikio/releases/download/v$version
curl -fsSLO "$base/sikio-$version-linux-$arch.tar.gz"
curl -fsSLO "$base/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
```

## 2. Create the user and directories

Each version is unpacked into a directory of its own, and a symlink names the current one:

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

The release directory stays owned by root; the service only reads it.

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

The secret signs sessions and must stay the same for the life of the instance. systemd reads
the file as root before it starts the service, so it stays unreadable for the service user.
[Operations](../operations.md#configure-and-start) lists every setting, PostgreSQL's included.

## 4. Install the unit and start

[sikio.service](../sikio.service) runs `bin/server` as the user `sikio`, creates
`/var/lib/sikio`, and keeps the rest of the system read-only for the service.

```sh
sudo curl -fsSL -o /etc/systemd/system/sikio.service \
  https://raw.githubusercontent.com/oliverandrich/sikio/main/docs/sikio.service
sudo systemctl daemon-reload
sudo systemctl enable --now sikio
journalctl -u sikio -f
```

On its first start Sikio creates the database and migrates it. A line `Running SikioWeb.Endpoint`
says it serves. Check it from the host:

```sh
curl -fsS http://127.0.0.1:4000/health
```

## 5. Put Caddy in front

```caddyfile
sikio.example.org {
	reverse_proxy 127.0.0.1:4000
}
```

Caddy fetches the certificate and forwards the visitor's address; Sikio trusts the loopback
already. Reload Caddy and open `https://sikio.example.org`.

## 6. Claim the instance

The first account needs a code that only the operator can issue. Run it with the service's
user and environment:

```sh
sudo systemd-run --uid=sikio --gid=sikio -p EnvironmentFile=/etc/sikio/sikio.env \
  --pipe --wait /opt/sikio/current/bin/setup-code
```

It prints the code once. Open your domain, enter the code, choose your username and create a
passkey. Save the recovery codes the next page shows; they are shown once. A new code replaces
a lost one. [Operations](../operations.md#claim-the-instance) has the details.

Everybody after you arrives on an invitation, made under Invitations in the account menu.

## 7. Back up

`sqlite3` copies a running database consistently, including what the write-ahead log holds:

```sh
sudo -u sikio sqlite3 /var/lib/sikio/sikio.db ".backup /var/lib/sikio/backup-$(date +%F).db"
```

Move the copy off the host, and keep `/etc/sikio/sikio.env` with it; without its secret every
session ends. With PostgreSQL, use `pg_dump` instead.

## 8. Update

Read the version's entry in the [changelog](../../CHANGELOG.md) first. Back up, download and
verify the new version as in step 1, then:

```sh
sudo mkdir -p /opt/sikio/releases/$version
sudo tar -xzf sikio-$version-linux-$arch.tar.gz -C /opt/sikio/releases/$version --strip-components=1
sudo ln -sfn releases/$version /opt/sikio/current
sudo systemctl restart sikio
curl -fsS http://127.0.0.1:4000/health
```

The restart migrates the database. Keep the previous directory until the update is verified.
Going back is not only switching the symlink: an older release does not undo a newer one's
migrations. Restore the backup, or roll back as in
[Operations](../operations.md#migration-rollback) before you start the older release.
