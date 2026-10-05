# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    %{conn: conn, user: user}
  end

  # Managing is its own page: the subscriptions and the OPML file, no search.
  test "the page manages subscriptions and adds none", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    assert has_element?(view, "#subscriptions-empty")
    assert has_element?(view, "#opml-import-link")
    assert has_element?(view, "#opml-export-link")
    refute has_element?(view, "#discover-form")
    refute has_element?(view, "#search-form")
  end

  # The sidebar's mark says it only on hover. Here the reason is written out, for keyboards and
  # touch screens too.
  test "a source whose last refresh failed says why", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)

    Repo.update_all(from(f in Feed, where: f.id == ^subscription.feed_id),
      set: [last_error: "gone"]
    )

    {:ok, view, _} = live(conn, ~p"/subscriptions")
    assert has_element?(view, "#subscription-#{subscription.id}", "no longer exists")
    assert render(view) =~ ~r/\b1 source\s*</
  end

  test "pausing and unsubscribing act only on our own rows", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#subscription-#{subscription.id} button", "Pause") |> render_click()
    assert [%{paused: true}] = Library.subscriptions(user)

    view |> element("#subscription-#{subscription.id} button", "Resume") |> render_click()
    assert [%{paused: false}] = Library.subscriptions(user)

    view |> element("#subscription-#{subscription.id} button", "Unsubscribe") |> render_click()
    assert Library.subscriptions(user) == []
    assert has_element?(view, "#subscriptions-empty")
  end
end
