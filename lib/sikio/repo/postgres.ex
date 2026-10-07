# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Postgres do
  @moduledoc "The repository for PostgreSQL. Reached through `Sikio.Repo`."

  @defaults []

  # `Sikio.Repo`, spelled from this module's name. Naming it, or sharing this module's code with
  # the other repository through a module of their own, would make this file depend on others while
  # `Sikio.Repo` reads its functions when it compiles. The two repositories repeat it instead.
  @name __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  # It runs under that name, so whoever asks for `Sikio.Repo` by name finds it, and its own
  # calls go there too.
  use Ecto.Repo, otp_app: :sikio, adapter: Ecto.Adapters.Postgres, default_dynamic_repo: @name

  # Started through `Sikio.Repo`, the configuration set there already lies beneath the start's
  # own options. Asked for its configuration without a start, it lies above Ecto's defaults.
  # The adapter's defaults lie beneath both. Migrations and telemetry keep the names of a
  # single repository.
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
