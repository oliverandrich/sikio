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
