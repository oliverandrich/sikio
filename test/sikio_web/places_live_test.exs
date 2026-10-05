# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlacesLiveTest do
  @moduledoc """
  The Library page: every place of the library as a grouped list, which a phone moves through
  instead of the sidebar.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, sub} = Library.subscribe(user, preview)
    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user), user: user, sub: sub}
  end

  test "lists the views, the tags and the subscriptions, each leading to its list", c do
    {:ok, [tag]} = Sikio.Tags.set(c.user, c.sub.id, ["Must view"])
    {:ok, view, _} = live(c.conn, ~p"/library")

    # What is new and what is in progress have tabs of their own.
    refute has_element?(view, ~s|#places-views a[href="/queue"]|)
    assert has_element?(view, ~s|#places-views a[href="/history"]|, "History")
    assert has_element?(view, ~s|#places-views a[href="/all"]|, "All items")
    assert has_element?(view, ~s|#places-tags a[href="/tags/#{tag.id}-must-view"]|, "Must view")
    assert has_element?(view, "#places-tags a", "1")

    assert has_element?(
             view,
             ~s|#places-sources a[href="/feeds/#{c.sub.feed_id}-small-hours"]|,
             "Small Hours"
           )

    view |> element(~s|#places-sources a[href^="/feeds/"]|) |> render_click()
    assert_redirect(view, "/feeds/#{c.sub.feed_id}-small-hours")
  end

  # On a phone the sources are managed from the head of their group.
  test "leads from the subscriptions' heading to managing them", c do
    {:ok, view, _} = live(c.conn, ~p"/library")
    assert has_element?(view, ~s|#places-sources #places-manage[href="/subscriptions"]|, "Manage")
  end

  test "has no tags section without tags", c do
    {:ok, view, _} = live(c.conn, ~p"/library")
    refute has_element?(view, "#places-tags")
  end
end
