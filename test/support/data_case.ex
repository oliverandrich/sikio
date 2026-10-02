# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Sikio.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.Identity.Instance

  @doc """
  A name no other test writes.

  Almost every test file is `async: true`, each in its own sandbox transaction. Two of them
  writing the same account row take the same lock, and taking two such locks in opposite order
  is how a suite deadlocks against itself. The cheapest way out is for no two tests to name the
  same row. The prefix is for whoever reads the test, not for the database.
  """
  def unique_username(prefix \\ "reader"), do: prefix <> unique()

  @doc "The tail that makes a name or an address this test's own."
  def unique, do: Integer.to_string(System.unique_integer([:positive]))

  @doc """
  Runs `fun` and returns its result with the SQL that process `pid` sent meanwhile.

  Repo telemetry runs in the process that queries, so other tests' queries never arrive here.
  """
  def queries(pid \\ self(), fun) do
    test = self()
    handler = "queries-#{unique()}"

    :telemetry.attach(
      handler,
      [:sikio, :repo, :query],
      &__MODULE__.forward_query/4,
      {pid, test, handler}
    )

    try do
      result = fun.()
      {result, collect_queries(handler, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  # A module's function, because telemetry warns about a closure and calls it more slowly.
  def forward_query(_event, _measurements, %{query: query}, {pid, test, handler}) do
    if self() == pid, do: send(test, {handler, query})
  end

  defp collect_queries(handler, sql) do
    receive do
      {^handler, query} -> collect_queries(handler, [query | sql])
    after
      0 -> Enum.reverse(sql)
    end
  end

  @doc """
  What the operator's code buys, for a test that makes the first account.

  Every instance protects its claim, so nothing claims one without this. Bought by issuing a code
  and spending it, rather than by writing a proof by hand, so the test walks the same path an
  operator does.

  Issued once per test and remembered. Issuing another code is what makes the previous one
  worthless, so a helper that issued one per call would hand back proofs that the next call voids.
  """
  def setup_authorization do
    case Process.get(__MODULE__) do
      nil ->
        {:ok, code} = Instance.issue_code()
        {:ok, proof} = Instance.authorize_code(code)
        Process.put(__MODULE__, proof)
        proof

      proof ->
        proof
    end
  end

  @doc "A connection that has already spent the operator's code, with a session to hold it."
  def claiming_conn(conn \\ Phoenix.ConnTest.build_conn()) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:setup_authorization, setup_authorization())
  end

  using do
    quote do
      alias Sikio.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Sikio.DataCase
    end
  end

  setup tags do
    Sikio.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Sikio.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
