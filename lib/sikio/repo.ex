# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo do
  @moduledoc """
  The application's database: SQLite or Postgres, whichever the build was compiled for.
  """
  use Ecto.Repo,
    otp_app: :sikio,
    adapter:
      (case Application.compile_env!(:sikio, :database) do
         :sqlite -> Ecto.Adapters.SQLite3
         :postgres -> Ecto.Adapters.Postgres
       end)

  @doc """
  Locks the rows `query` selects until the transaction ends. Postgres locks the rows. A SQLite
  transaction already holds the database's only write lock from its start, so it needs none.
  """
  if Application.compile_env!(:sikio, :database) == :sqlite do
    def for_update(query), do: query
  else
    import Ecto.Query, only: [lock: 2]

    def for_update(query), do: lock(query, "FOR UPDATE")
  end
end
