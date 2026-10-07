#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Starts the image once with SQLite and once with PostgreSQL and asks each for its first page.
# Usage: scripts/smoke_image.sh IMAGE
# It needs Docker with host networking, as on Linux, and PGHOST, PGPORT, PGUSER and PGPASSWORD
# for a PostgreSQL server that grants CREATEDB, as in CI. Each start migrates an empty database
# as it boots, which is what the page proves.
set -eu

image="$1"
key="$(openssl rand -hex 64)"
data="$(mktemp -d)"
database="sikio_image_$(openssl rand -hex 4)"
chmod 777 "$data"

cleanup() {
  docker rm -f sikio-image-sqlite sikio-image-postgres >/dev/null 2>&1 || true
  PGPASSWORD="${PGPASSWORD:-}" dropdb --if-exists "$database" >/dev/null 2>&1 || true
  rm -rf "$data"
}
trap cleanup EXIT

# An unclaimed instance sends its first visitor to the page that claims it.
landing() {
  for _ in $(seq 1 60); do
    if curl -fsSL "http://127.0.0.1:$1/" 2>/dev/null | grep -q 'id="setup-code-form"'; then
      echo "$2: the image migrated and serves the setup page."
      return 0
    fi
    sleep 1
  done
  docker logs "$3" || true
  echo "$2: the image never served the setup page." >&2
  return 1
}

docker run -d --name sikio-image-sqlite -p 127.0.0.1:4601:4000 -v "$data:/data" \
  -e SECRET_KEY_BASE="$key" -e PHX_HOST=localhost "$image" >/dev/null
landing 4601 sqlite sikio-image-sqlite
test -f "$data/sikio.db" || { echo "sqlite: no database in /data" >&2; exit 1; }

createdb "$database"
encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
docker run -d --name sikio-image-postgres --network host \
  -e PORT=4602 -e SIKIO_DATABASE=postgres \
  -e DATABASE_URL="ecto://$(encode "$PGUSER"):$(encode "$PGPASSWORD")@${PGHOST}:${PGPORT}/${database}" \
  -e SECRET_KEY_BASE="$key" -e PHX_HOST=localhost "$image" >/dev/null
landing 4602 postgres sikio-image-postgres
