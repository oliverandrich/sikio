# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Postgres do
  @moduledoc "The repository for PostgreSQL. Reached through `Sikio.Repo`."

  @defaults []

  # `Sikio.Repo`, derived from this module's name. `Sikio.Repo` reads this module's functions
  # at compile time. Naming it here, or sharing code through a third module, adds a dependency
  # to this file. So both repositories repeat this line.
  @name __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  # The repository registers under that name, so name lookups for `Sikio.Repo` find it.
  # Its own calls default to that name too.
  use Ecto.Repo, otp_app: :sikio, adapter: Ecto.Adapters.Postgres, default_dynamic_repo: @name

  # Under `:supervisor`, `Sikio.Repo` has already merged its configuration beneath the start
  # options. Under `:runtime`, the `Sikio.Repo` configuration overrides the given one.
  # `@defaults` sit beneath both. `priv` and the telemetry prefix match a single repository.
  @impl true
  def init(type, config) do
    config =
      if type == :runtime,
        do: Keyword.merge(config, Application.get_env(:sikio, @name, [])),
        else: config

    config =
      @defaults
      |> Keyword.merge(config)
      |> Keyword.put_new(:priv, "priv/repo")
      |> Keyword.put(:telemetry_prefix, [:sikio, :repo])

    {:ok, config}
  end
end
