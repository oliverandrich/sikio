# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo do
  @moduledoc """
  The application's database: SQLite or PostgreSQL, whichever `:database` names when it starts.

  Ecto fixes a repository's adapter when it compiles. So each database has a repository of its
  own, `Sikio.Repo.SQLite` and `Sikio.Repo.Postgres`, and this module hands every call on to the
  one chosen. Both read their configuration from `Sikio.Repo`. Neither calls back into this
  module, which reads their functions when it compiles.
  """

  import Ecto.Query, only: [lock: 2]

  alias Sikio.Repo.Postgres
  alias Sikio.Repo.SQLite

  @doc "The repository the configuration chose."
  def repo do
    case Application.fetch_env!(:sikio, :database) do
      :sqlite -> SQLite
      :postgres -> Postgres
    end
  end

  @doc "Whether the chosen database is PostgreSQL."
  def postgres?, do: repo() == Postgres

  # Every function a repository has, handed on. Both repositories have the same ones.
  for {name, arity} <- SQLite.__info__(:functions),
      name not in [:init, :start_link, :child_spec] do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: repo().unquote(name)(unquote_splicing(args))
  end

  # The chosen repository runs under this module's name. Code that asks for a repository by name,
  # as `Ecto.Adapters.SQL.query/4` does, finds it there. It starts with the configuration set for
  # this module, beneath whatever the start names itself and above Ecto's own defaults.
  def child_spec(opts), do: repo().child_spec(started(opts))
  def start_link(opts \\ []), do: repo().start_link(started(opts))

  defp started(opts) do
    :sikio
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
    |> Keyword.put_new(:name, __MODULE__)
  end

  @doc """
  Locks the rows `query` selects until the transaction ends. Postgres locks the rows. A SQLite
  transaction already holds the database's only write lock from its start, so it needs none.
  """
  def for_update(query), do: if(postgres?(), do: lock(query, "FOR UPDATE"), else: query)

  @doc """
  Locks the rows `query` selects against each other, as `for_update/1` does, without stopping an
  insert that refers to them. Postgres checks such a reference with a lock this one allows.
  """
  def for_no_key_update(query),
    do: if(postgres?(), do: lock(query, "FOR NO KEY UPDATE"), else: query)
end
