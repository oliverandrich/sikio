# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsShownTest do
  @moduledoc """
  The sidebar and the phone's Library page list all subscriptions or those with new items.
  The account's preferences keep the choice.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Preferences
  alias Sikio.Repo

  # "Fresh" has an unheard item. Every item of "Done" is heard.
  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, fresh} = Library.subscribe(user, parsed("Fresh"))
    {:ok, done} = Library.subscribe(user, parsed("Done"))

    for entry <- Library.entries(user, %{"source" => to_string(done.feed_id)}),
        do: {:ok, _} = Playback.mark(user, entry.id, :heard)

    %{
      conn: conn |> init_test_session(%{}) |> Gate.log_in(user),
      user: user,
      fresh: fresh,
      done: done
    }
  end

  defp parsed(title) do
    {:ok, preview} = Parser.parse(podcast(title), feed_url())
    preview
  end

  test "the sidebar shows all subscriptions, or those with new items, and keeps the choice", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    assert has_element?(view, "#source-#{c.done.feed_id}")
    assert has_element?(view, ~s|#subscriptions-all[aria-pressed="true"]|)

    view |> element("#subscriptions-new") |> render_click()
    assert has_element?(view, "#source-#{c.fresh.feed_id}")
    refute has_element?(view, "#source-#{c.done.feed_id}")
    assert has_element?(view, ~s|#subscriptions-new[aria-pressed="true"]|)
    assert %{subscriptions_shown: "new"} = Preferences.get(c.user)

    {:ok, view, _} = live(c.conn, ~p"/inbox")
    refute has_element?(view, "#source-#{c.done.feed_id}")

    view |> element("#subscriptions-all") |> render_click()
    assert has_element?(view, "#source-#{c.done.feed_id}")
  end

  # The sidebar is on every member page, so the switch works outside the library too.
  test "the switch works on a page outside the library", c do
    {:ok, view, _} = live(c.conn, ~p"/invitations")
    view |> element("#subscriptions-new") |> render_click()
    refute has_element?(view, "#source-#{c.done.feed_id}")
  end

  # A library change reloads the sidebar. The choice stays, and a source with a new item returns.
  test "a library change keeps the choice and brings back a source with a new item", c do
    {:ok, _} = Preferences.update(c.user, %{subscriptions_shown: "new"})
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    refute has_element?(view, "#source-#{c.done.feed_id}")

    [entry | _] = Library.entries(c.user, %{"source" => to_string(c.done.feed_id)})
    {:ok, _} = Playback.mark(c.user, entry.id, :new)
    assert has_element?(view, "#source-#{c.done.feed_id}")

    {:ok, _} = Playback.mark(c.user, entry.id, :heard)
    refute has_element?(view, "#source-#{c.done.feed_id}")
  end

  # The open source and a source that failed to refresh stay in the list.
  test "the open source and a failing source stay listed", c do
    {:ok, _} = Preferences.update(c.user, %{subscriptions_shown: "new"})

    path =
      SikioWeb.LibraryPaths.place_path("source", to_string(c.done.feed_id), %{
        c.done.feed_id => "Done"
      })

    {:ok, view, _} = live(c.conn, path)

    assert has_element?(view, "#source-#{c.done.feed_id}[aria-current=page]")

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Sikio.Feeds.Feed, c.done.feed_id),
        last_error: "timeout"
      )
    )

    {:ok, view, _} = live(c.conn, ~p"/inbox")
    assert has_element?(view, "#source-#{c.done.feed_id}")
  end

  test "the phone's Library page has the same switch", c do
    {:ok, view, _} = live(c.conn, ~p"/library")
    assert has_element?(view, "#places-sources", "Done")

    view |> element("#places-subscriptions-new") |> render_click()
    assert has_element?(view, "#places-sources", "Fresh")
    refute has_element?(view, "#places-sources", "Done")
    assert has_element?(view, ~s|#places-subscriptions-new[aria-pressed="true"]|)
  end
end
