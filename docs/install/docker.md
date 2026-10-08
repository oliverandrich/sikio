# Run Sikio with Docker

This guide runs the Sikio image with Docker Compose on a Linux host, behind Caddy. Caddy
obtains the TLS certificate. The last steps claim the instance and register your passkey.
[Operations](../operations.md) documents every setting.

## What you need

- A Linux host, amd64 or arm64, with Docker Engine and the Compose plugin.
- A domain name that resolves to the host, for example `sikio.example.org`. Passkeys are bound
  to the domain they are created on, so use the final domain from the start.
- Caddy on the same host, or another reverse proxy that terminates TLS and supports WebSockets.

The image is `ghcr.io/oliverandrich/sikio`. Each version is tagged `X.Y.Z`, `X.Y` and `latest`.
The `X.Y` tag receives patch releases, which contain no migrations. A new minor version may
contain migrations. Switch to it by changing the tag manually.

## 1. Lay out the directory

```sh
mkdir -p /opt/sikio && cd /opt/sikio
curl -fsSLO https://raw.githubusercontent.com/oliverandrich/sikio/main/docs/compose.yaml
```

[compose.yaml](../compose.yaml) runs the image with SQLite and stores its data in the volume
`sikio-data`. It publishes the port on the loopback only, for Caddy. Set `PHX_HOST` to your
domain.

## 2. Write the environment file

`SECRET_KEY_BASE` signs sessions. Never change it after the first start.

```sh
umask 077
printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 48 | tr -d '\n')" > sikio.env
```

Add further settings to the same file, one `NAME=value` per line. See
[Operations](../operations.md#configure-and-start). Keep `sikio.env` out of version control.
On a small host, these two settings lower memory use:

```sh
printf 'ERL_AFLAGS=+S 2:2\nRELEASE_MODE=interactive\n' >> sikio.env
```

[Operations](../operations.md#small-installations) explains what they do.

## 3. Start it

```sh
docker compose up -d
docker compose logs -f sikio
```

On the first start, the migration creates the SQLite database. The log line
`Running SikioWeb.Endpoint` means the server accepts requests. Check it from the host:

```sh
curl -fsS http://127.0.0.1:4000/health
```

## 4. Put Caddy in front

```caddyfile
sikio.example.org {
	reverse_proxy 127.0.0.1:4000
}
```

Caddy obtains the certificate and sends the client address in `X-Forwarded-For`. Inside the
container, connections come from the network gateway. `compose.yaml` fixes the gateway at
`172.30.0.1` and lists it in `TRUSTED_PROXIES`. Reload Caddy and open `https://sikio.example.org`.

## 5. Claim the instance

The first account requires a setup code. Issue it on the host:

```sh
docker compose exec sikio bin/setup-code
```

The command prints the code once. Open your domain, enter the code, choose a username and
create a passkey. Save the recovery codes on the next page, which are shown only once. If the
code is lost, issue a new one. See [Operations](../operations.md#claim-the-instance) for details.

Further members join through invitations. Create them under Settings, then Invitations, in
the gear menu.

## 6. Back up

The volume holds the SQLite database and the picture cache. Stop Sikio for a consistent copy:

```sh
docker compose stop sikio
docker run --rm -v sikio_sikio-data:/data -v "$PWD":/backup busybox \
  tar -czf /backup/sikio-data-$(date +%F).tar.gz -C /data .
docker compose start sikio
```

The volume name is prefixed with the Compose project name. That is the directory name, here
`sikio`. `docker volume ls` lists it. Keep `sikio.env` with the backup. With a different
`SECRET_KEY_BASE`, all existing sessions become invalid.

## 7. Update

Read the version's entry in the [changelog](../../CHANGELOG.md) first. Back up, then:

```sh
docker compose pull
docker compose up -d
docker compose logs -f sikio
```

The new version migrates the database on start. For a new minor version, change the tag in
`compose.yaml` before pulling. To go back, restore the backup. An older version does not revert
a newer version's migrations.

## With PostgreSQL

Sikio migrates a PostgreSQL database but does not create it. Create the database and its owner
before the first start.

### Its own database container

Add a database service and set Sikio's `DATABASE_URL` to it. On an empty volume, the `postgres`
image creates the database named in `POSTGRES_DB`. In `compose.yaml`:

```yaml
services:
  sikio:
    # as before, plus:
    environment:
      SIKIO_DATABASE: postgres
      DATABASE_URL: ecto://sikio:${POSTGRES_PASSWORD}@db/sikio
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:18
    restart: unless-stopped
    environment:
      POSTGRES_USER: sikio
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: sikio
    volumes:
      - sikio-db:/var/lib/postgresql
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "sikio"]
      interval: 10s

volumes:
  sikio-data:
  sikio-db:
```

Set `POSTGRES_PASSWORD=` to a long random value in a file `.env` beside `compose.yaml`.
Compose reads it to substitute `${…}`. Sikio's volume then holds only the picture cache. Back up
the database with `pg_dump`:

```sh
docker compose exec db pg_dump -U sikio sikio | gzip > sikio-$(date +%F).sql.gz
```

### A shared database and Caddy on Docker networks

A host may run one PostgreSQL server and one Caddy for several services. Each is attached to
its own Docker network. Here the database server is `postgres` on the network `db`. Caddy is on
the network `caddy` and reads its configuration from container labels. The administrator creates
a database and an owner for Sikio:

```sql
CREATE ROLE sikio LOGIN PASSWORD '…';
CREATE DATABASE sikio OWNER sikio;
```

Sikio is attached to both networks and publishes no port:

```yaml
services:
  sikio:
    image: ghcr.io/oliverandrich/sikio:0.1
    restart: unless-stopped
    env_file: sikio.env
    environment:
      PHX_HOST: sikio.example.org
      SIKIO_DATABASE: postgres
      DATABASE_URL: ecto://sikio:${SIKIO_DB_PASSWORD}@postgres/sikio
      # The caddy network's subnet, from `docker network inspect caddy`.
      TRUSTED_PROXIES: 172.20.0.0/16
    labels:
      caddy: sikio.example.org
      caddy.reverse_proxy: "{{upstreams 4000}}"
    networks: [db, caddy]
    volumes:
      - sikio-data:/data

volumes:
  sikio-data:

networks:
  db:
    external: true
  caddy:
    external: true
```

Caddy connects from its address on the `caddy` network. That address changes when the Caddy
container is recreated, so `TRUSTED_PROXIES` lists the whole subnet. The volume holds only the
picture cache. Sikio downloads missing pictures again. Database backups are the administrator's
responsibility. Issue the setup code as in step 5.
