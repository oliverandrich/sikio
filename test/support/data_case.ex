# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.DataCase do
  @moduledoc """
  Test case for tests that use the Repo.

  Imports `Ecto`, `Ecto.Changeset`, `Ecto.Query` and the helpers below.
  Each test runs in an SQL sandbox transaction that is rolled back afterwards.
  The sandbox is shared when the test is not `async`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.Identity.Instance

  @doc """
  Returns a username that no other test uses.

  Most test files are `async: true`, each in its own sandbox transaction.
  Two tests writing the same account row take the same row lock.
  Taking two such locks in opposite order deadlocks the suite.
  Unique names avoid shared rows. The prefix only aids readability.
  """
  def unique_username(prefix \\ "reader"), do: prefix <> unique()

  @doc "Returns a positive integer, unique within the VM, as a string suffix for names."
  def unique, do: Integer.to_string(System.unique_integer([:positive]))

  @doc """
  Runs `fun` and returns `{result, sql}` with the queries that process `pid` sent meanwhile.

  Repo telemetry handlers run in the querying process, so other tests' queries are not collected.
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
  # A named function, because telemetry warns about anonymous handlers and calls them slower.
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
  Returns a setup authorization proof for a test that creates the first account.

  Claiming an instance requires this proof.
  The proof comes from issuing and authorizing a real code, the same path an operator takes.

  The proof is cached in the process dictionary for the test.
  Issuing a new code invalidates the previous one.
  A fresh code per call would therefore void earlier proofs.
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

  @doc "Returns a conn whose session holds the setup authorization proof."
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
  Transforms changeset errors into a map of messages.

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
