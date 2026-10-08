# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ConnCase do
  @moduledoc """
  Test case for tests that need a `Plug.Conn`.

  Imports `Phoenix.ConnTest`, verified routes and helpers from `Sikio.DataCase`.
  Each test runs in an SQL sandbox transaction that is rolled back afterwards.
  The sandbox is shared when the test is not `async`.
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
      @endpoint SikioWeb.Endpoint

      use SikioWeb, :verified_routes

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

  @doc "Returns an entry's path in the unfiltered library list, as `SikioWeb.LibraryPaths` builds it."
  def item_path(entry), do: SikioWeb.LibraryPaths.library_path(%{"status" => ""}, entry)

  @doc """
  Setup callback: a signed-in account subscribed to one podcast with one episode.

  Returns the conn, the account as `user`, the episode as `entry` and the subscription as `sub`.
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
