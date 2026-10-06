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

  import Ecto.Query, only: [lock: 2]

  @postgres Application.compile_env!(:sikio, :database) == :postgres

  @doc """
  Locks the rows `query` selects until the transaction ends. Postgres locks the rows. A SQLite
  transaction already holds the database's only write lock from its start, so it needs none.
  """
  def for_update(query), do: if(@postgres, do: lock(query, "FOR UPDATE"), else: query)

  @doc """
  Locks the rows `query` selects against each other, as `for_update/1` does, without stopping an
  insert that refers to them. Postgres checks such a reference with a lock this one allows.
  """
  def for_no_key_update(query),
    do: if(@postgres, do: lock(query, "FOR NO KEY UPDATE"), else: query)
end
