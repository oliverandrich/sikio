# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Sikio's image, after the one `mix phx.gen.release --docker` writes. One image serves SQLite and
# PostgreSQL; SIKIO_DATABASE chooses when it starts. See docs/operations.md.
#
# The release workflow passes the Elixir and OTP versions from mise.toml; these defaults serve a
# build by hand. The Debian date is one hexpm/elixir has built for both amd64 and arm64.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# exqlite downloads a precompiled NIF when one fits and compiles SQLite when none does.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Configuration read when compiling; config/runtime.exs comes later, so changing it rebuilds less.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix compile --warnings-as-errors

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# What Sikio keeps lives in /data: the SQLite file and the picture cache. A PostgreSQL instance
# sets SIKIO_DATABASE=postgres and DATABASE_URL, and keeps only pictures there.
ENV DATABASE_PATH=/data/sikio.db
ENV PICTURE_CACHE_DIR=/data/pictures
RUN mkdir /data && chown nobody /data
VOLUME /data

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/sikio ./

USER nobody

EXPOSE 4000

# bin/server migrates the database before it serves, unless SIKIO_MIGRATE_ON_START=false.
CMD ["/app/bin/server"]
