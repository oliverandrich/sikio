# Run Sikio with Docker

This guide runs Sikio's image with Docker Compose on a Linux host, behind Caddy, which gets
the TLS certificate. At the end the instance is claimed and you have signed in with a passkey.
[Operations](../operations.md) is the reference for every setting.

## What you need

- A Linux host, amd64 or arm64, with Docker Engine and the Compose plugin.
- A domain name pointing at the host, for example `sikio.example.org`. Passkeys are bound to
  the name they are made on, so choose the final one now.
- Caddy on the same host, or another proxy that terminates TLS and supports WebSockets.

The image is `ghcr.io/oliverandrich/sikio`. Each version is tagged `X.Y.Z`, its minor line
`X.Y` and `latest`. Following `X.Y` brings fixes without a migration; a new minor version may
migrate the database and is chosen by hand.

## 1. Lay out the directory

```sh
mkdir -p /opt/sikio && cd /opt/sikio
curl -fsSLO https://raw.githubusercontent.com/oliverandrich/sikio/main/docs/compose.yaml
```

[compose.yaml](../compose.yaml) runs the image with SQLite, keeps its data in the volume
`sikio-data`, and publishes the port on the loopback only, for Caddy. Change `PHX_HOST` to your
domain.

## 2. Write the environment file

The secret signs sessions and must stay the same for the life of the instance.

```sh
umask 077
printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 48 | tr -d '\n')" > sikio.env
```

Further settings go into the same file, one `NAME=value` per line; see
[Operations](../operations.md#configure-and-start). Keep `sikio.env` out of version control.

## 3. Start it

```sh
docker compose up -d
docker compose logs -f sikio
```

On its first start Sikio creates the database and migrates it. A line `Running SikioWeb.Endpoint`
says it serves. Check it from the host:

```sh
curl -fsS http://127.0.0.1:4000/health
```

## 4. Put Caddy in front

```caddyfile
sikio.example.org {
	reverse_proxy 127.0.0.1:4000
}
```

Caddy fetches the certificate and forwards the visitor's address. Sikio sees the connection
from the container network's gateway, which `compose.yaml` fixes at `172.30.0.1` and names in
`TRUSTED_PROXIES`. Reload Caddy and open `https://sikio.example.org`.

## 5. Claim the instance

The first account needs a code that only the operator can issue:

```sh
docker compose exec sikio bin/setup-code
```

It prints the code once. Open your domain, enter the code, choose your username and create a
passkey. Save the recovery codes the next page shows; they are shown once. A new code replaces
a lost one. [Operations](../operations.md#claim-the-instance) has the details.

Everybody after you arrives on an invitation, made under Invitations in the account menu.

## 6. Back up

The volume holds everything Sikio keeps. A copy taken while Sikio is stopped is consistent:

```sh
docker compose stop sikio
docker run --rm -v sikio_sikio-data:/data -v "$PWD":/backup busybox \
  tar -czf /backup/sikio-data-$(date +%F).tar.gz -C /data .
docker compose start sikio
```

The volume's name starts with the Compose project, which is the directory's name, here `sikio`.
`docker volume ls` lists it. Keep `sikio.env` with the backup; without its secret every session
ends.

## 7. Update

Read the version's entry in the [changelog](../../CHANGELOG.md) first. Back up, then:

```sh
docker compose pull
docker compose up -d
docker compose logs -f sikio
```

The new version migrates the database as it starts. For a new minor version, change the tag in
`compose.yaml` before pulling. Going back means restoring the backup, since an older version
does not undo a newer one's migrations.

## With PostgreSQL

Sikio migrates a PostgreSQL database but does not create it. The database and its owner must
exist before the first start.

### Its own database container

Add a database service and point Sikio at it. The `postgres` image creates the database named
in `POSTGRES_DB` when it starts on an empty volume. In `compose.yaml`:

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

Put `POSTGRES_PASSWORD=` with a long random value into a file `.env` beside `compose.yaml`,
which Compose reads for `${…}`. Sikio's volume then holds only the picture cache. Back up the
database with `pg_dump`:

```sh
docker compose exec db pg_dump -U sikio sikio | gzip > sikio-$(date +%F).sql.gz
```

### A shared database and Caddy on Docker networks

A host may run one PostgreSQL and one Caddy for several services, each reached on a Docker
network of its own: here `db`, where the database answers as `postgres`, and `caddy`, where a
Caddy that reads container labels finds the services. The administrator creates a database and
an owner for Sikio:

```sql
CREATE ROLE sikio LOGIN PASSWORD '…';
CREATE DATABASE sikio OWNER sikio;
```

Sikio then joins both networks and publishes no port:

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

Caddy reaches Sikio from its own address on the `caddy` network, which changes when its
container is made again, so `TRUSTED_PROXIES` names the network's whole subnet. The volume holds
only the picture cache, which Sikio fetches again when it is gone; the database's backup is the
administrator's. Get the setup code as in step 5.
