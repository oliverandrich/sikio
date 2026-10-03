# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SikioWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.DataCase
  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo

  using do
    quote do
      # The default endpoint for testing
      @endpoint SikioWeb.Endpoint

      use SikioWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SikioWeb.ConnCase

      import Sikio.DataCase,
        only: [
          unique_username: 0,
          unique_username: 1,
          claiming_conn: 0,
          claiming_conn: 1,
          setup_authorization: 0
        ]
    end
  end

  setup tags do
    Sikio.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "An item's address in the list of all items, as the library itself spells it."
  def item_path(entry), do: SikioWeb.Sidebar.library_path(%{"status" => ""}, entry)

  @doc """
  A signed-in account subscribed to one podcast with one episode, for `setup`.

  Answers the connection, the account as `user`, the episode as `entry` and the subscription.
  """
  def sign_in_with_episode(%{conn: conn}) do
    user = Repo.insert!(User.changeset(%User{}, %{username: DataCase.unique_username()}))
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), FeedFixtures.feed_url())
    {:ok, sub} = Library.subscribe(user, preview)
    [entry] = Library.entries(user)

    %{
      conn: conn |> Phoenix.ConnTest.init_test_session(%{}) |> Gate.log_in(user),
      user: user,
      entry: entry,
      sub: sub
    }
  end
end
