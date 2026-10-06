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

  # How often a source is asked is the operator's choice, so the page says what it is.
  test "the page names how often its sources are asked", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, _} = Library.subscribe(user, preview)

    {:ok, view, _} = live(conn, ~p"/subscriptions")
    assert has_element?(view, "#polling-interval", "Active sources refresh every hour.")
  end

  test "an interval of whole hours reads in hours, any other in minutes" do
    interval = fn minutes ->
      render_component(&SikioWeb.SubscriptionsLive.polling_interval/1, minutes: minutes)
    end

    assert interval.(60) =~ "every hour."
    assert interval.(120) =~ "every 2 hours."
    assert interval.(90) =~ "every 90 minutes."
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

  # Each row pauses or resumes its polling from an icon and states which it is in.
  test "a row pauses and resumes its polling", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    row = "#subscription-#{subscription.id}"

    view |> element(~s|#{row} button[aria-label="Pause polling"]|) |> render_click()
    assert [%{paused: true}] = Library.subscriptions(user)
    assert has_element?(view, row, "Polling paused")

    view |> element(~s|#{row} button[aria-label="Resume polling"]|) |> render_click()
    assert [%{paused: false}] = Library.subscriptions(user)
  end

  # A row names its source and, behind the name, the address it is polled at.
  test "a row links its name to the source and shows the feed's address behind it", %{
    conn: conn,
    user: user
  } do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    address = String.replace_prefix(subscription.feed.url, "https://", "")

    assert has_element?(view, "#subscription-#{subscription.id}", "Small Hours")

    assert has_element?(
             view,
             ~s|#subscription-#{subscription.id} [title="#{subscription.feed.url}"]|,
             address
           )

    # The name leads to the source's own page in Sikio.
    assert has_element?(
             view,
             ~s|#subscription-#{subscription.id} a[href="/feeds/#{subscription.feed_id}-small-hours"]|,
             "Small Hours"
           )
  end

  # The source's own website opens in a new tab, after the pencil and before leaving.
  test "a row opens the source's website, when it has one", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    assert has_element?(
             view,
             ~s|#open-website-#{subscription.id}[href="#{podcast_site()}"][target="_blank"][rel~="noopener"]|
           )

    Repo.update_all(Feed, set: [page_url: nil])
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    refute has_element?(view, "#open-website-#{subscription.id}")
  end

  # The pencil opens the source's own dialog, and what it saves shows in the list at once.
  test "a row edits its subscription in the source's dialog", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#edit-subscription-#{subscription.id}") |> render_click()
    assert has_element?(view, "dialog#edit-subscription-confirm", "Small Hours")

    view |> form("#subscription-form", %{"name" => "Late Night"}) |> render_change()
    view |> element("#confirm-edit-subscription") |> render_click()

    refute has_element?(view, "#edit-subscription-confirm")
    assert [%{name: "Late Night"}] = Library.subscriptions(user)
    assert has_element?(view, "#subscription-#{subscription.id}", "Late Night")
  end

  # Escape closes the dialog and hands the focus back to the button that opened it.
  test "Escape closes the dialog and gives the focus back to its row", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#edit-subscription-#{subscription.id}") |> render_click()
    view |> element("#edit-subscription-confirm") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#edit-subscription-confirm")
    assert_push_event(view, "focus", %{id: "edit-subscription-" <> _})
  end

  # A second press on leaving arrives after the first has closed the dialog, and changes nothing.
  test "a second press on leaving from the dialog is harmless", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#edit-subscription-#{subscription.id}") |> render_click()
    view |> element("#unsubscribe") |> render_click()
    view |> with_target("#subscription-settings") |> render_hook("unsubscribe", %{})

    assert has_element?(view, "dialog#unsubscribe-confirm")
  end

  # Another tab may have left the subscription while this one edits it.
  test "saving a subscription left elsewhere says so", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#edit-subscription-#{subscription.id}") |> render_click()
    {:ok, _} = Library.unsubscribe(user, subscription.id)
    view |> element("#confirm-edit-subscription") |> render_click()

    refute has_element?(view, "#edit-subscription-confirm")
    assert render(view) =~ "Subscription not found."
  end

  # Leaving from the list asks first, as leaving from the library does.
  test "a row leaves its subscription after asking", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#leave-subscription-#{subscription.id}") |> render_click()
    assert has_element?(view, "dialog#unsubscribe-confirm", "Small Hours")
    assert [_] = Library.subscriptions(user)

    view |> element("#confirm-unsubscribe") |> render_click()
    assert Library.subscriptions(user) == []
    assert has_element?(view, "#subscriptions-empty")
  end
end
