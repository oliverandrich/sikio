# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo do
  @moduledoc """
  The application's repository. The `:database` setting selects SQLite or PostgreSQL at runtime.

  Ecto fixes a repository's adapter at compile time. So each database has its own repository,
  `Sikio.Repo.SQLite` and `Sikio.Repo.Postgres`, and this module delegates every call to the
  selected one. Both read their configuration from the `Sikio.Repo` key. This module reads their
  functions at compile time, so neither references it.
  """

  import Ecto.Query, only: [lock: 2]

  alias Sikio.Repo.Postgres
  alias Sikio.Repo.SQLite

  @doc "Returns the repository module selected by `:database`."
  def repo do
    case Application.fetch_env!(:sikio, :database) do
      :sqlite -> SQLite
      :postgres -> Postgres
    end
  end

  @doc "Returns whether the selected database is PostgreSQL."
  def postgres?, do: repo() == Postgres

  # Delegates every repository function except the start functions below.
  # Both repositories define the same functions.
  for {name, arity} <- SQLite.__info__(:functions),
      name not in [:init, :start_link, :child_spec] do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: repo().unquote(name)(unquote_splicing(args))
  end

  # The selected repository registers under this module's name, so name lookups find it.
  # `Ecto.Adapters.SQL.query/4` is one such lookup.
  # Start options override the `Sikio.Repo` configuration, which overrides Ecto's defaults.
  def child_spec(opts), do: repo().child_spec(started(opts))
  def start_link(opts \\ []), do: repo().start_link(started(opts))

  defp started(opts) do
    :sikio
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
    |> Keyword.put_new(:name, __MODULE__)
  end

  @doc """
  Locks the rows `query` selects until the transaction ends. PostgreSQL adds `FOR UPDATE`.
  SQLite returns `query` unchanged: an `:immediate` transaction holds the only write lock from
  its start.
  """
  def for_update(query), do: if(postgres?(), do: lock(query, "FOR UPDATE"), else: query)

  @doc """
  Locks the rows `query` selects against other row locks, but not against foreign key checks.
  PostgreSQL adds `FOR NO KEY UPDATE`. Foreign key checks take `FOR KEY SHARE`, which it
  allows, so inserts referencing the rows proceed. SQLite returns `query` unchanged.
  """
  def for_no_key_update(query),
    do: if(postgres?(), do: lock(query, "FOR NO KEY UPDATE"), else: query)
end
