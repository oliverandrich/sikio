# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Hub
  alias Sikio.Feeds.Parser
  alias Sikio.Feeds.Refresh
  alias Sikio.Library
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    %{conn: conn, user: user}
  end

  # The subscriptions page links OPML import and export and has no search or discovery form.
  test "the page manages subscriptions and adds none", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    assert has_element?(view, "#subscriptions-empty")
    assert has_element?(view, "#opml-import-link")
    assert has_element?(view, "#opml-export-link")
    refute has_element?(view, "#discover-form")
    refute has_element?(view, "#search-form")
  end

  # A YouTube channel whose hub subscription is verified shows Live; one still polling says so.
  # Other sources carry neither, since only YouTube has a hub.
  test "YouTube channels show whether their hub announces new videos", %{conn: conn, user: user} do
    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, video_sub} = Library.subscribe(user, video)
    {:ok, podcast} = Parser.parse(podcast(), feed_url())
    {:ok, podcast_sub} = Library.subscribe(user, podcast)
    feed = Repo.get!(Feed, video_sub.feed_id)

    {:ok, view, _} = live(conn, ~p"/subscriptions")
    assert has_element?(view, "#subscription-#{video_sub.id} [data-hub=polling]", "Polling")
    refute has_element?(view, "#subscription-#{podcast_sub.id} [data-hub]")

    {:ok, hub} = Hub.ensure(feed)
    {:ok, _} = Hub.verify(hub.token, Hub.topic(feed), 864_000)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    assert has_element?(view, "#subscription-#{video_sub.id} [data-hub=live]", "Live")
    assert has_element?(view, "#polling-interval", "Live channels are also checked once a day.")
  end

  # The operator configures the poll interval, so the page states it.
  test "the page names how often its sources are asked", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, _} = Library.subscribe(user, preview)

    {:ok, view, _} = live(conn, ~p"/subscriptions")

    assert has_element?(
             view,
             "#polling-interval",
             "Active sources refresh at most every hour, less often when they rarely publish."
           )
  end

  test "an interval of whole hours reads in hours, any other in minutes" do
    interval = fn minutes ->
      render_component(&SikioWeb.SubscriptionsLive.polling_interval/1, minutes: minutes)
    end

    assert interval.(60) =~ "at most every hour,"
    assert interval.(120) =~ "at most every 2 hours,"
    assert interval.(90) =~ "at most every 90 minutes,"
  end

  # The sidebar shows the error only in a hover title. This page prints it for keyboard and touch.
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

  # Row buttons pause and resume polling. A paused row shows "Polling paused".
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

  # A row shows the feed name and the feed URL without scheme. The `title` holds the full URL.
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

    # The name links to the feed's page in Sikio.
    assert has_element?(
             view,
             ~s|#subscription-#{subscription.id} a[href="/feeds/#{subscription.feed_id}-small-hours"]|,
             "Small Hours"
           )
  end

  # The website link opens in a new tab with `rel=noopener`. Without `page_url` it is absent.
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

  # The edit button opens the subscription dialog. A saved name appears in the row immediately.
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

  # Escape closes the dialog and pushes a `focus` event for the row's edit button.
  test "Escape closes the dialog and pushes a focus event for its row", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#edit-subscription-#{subscription.id}") |> render_click()
    view |> element("#edit-subscription-confirm") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#edit-subscription-confirm")
    assert_push_event(view, "focus", %{id: "edit-subscription-" <> _})
  end

  # A second `unsubscribe` event can arrive after the first closed the edit dialog.
  # The confirm dialog stays open.
  test "a second press on leaving from the dialog is harmless", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#edit-subscription-#{subscription.id}") |> render_click()
    view |> element("#unsubscribe") |> render_click()
    view |> with_target("#subscription-settings") |> render_hook("unsubscribe", %{})

    assert has_element?(view, "dialog#unsubscribe-confirm")
  end

  # Another tab can delete the subscription while the dialog is open. Saving then shows an error.
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

  # Unsubscribing from a row requires confirmation. The subscription stays until confirmed.
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

  # The row stays busy until the job reports, then shows the job's result without a reload.
  test "a row refreshes its source and shows the result", %{conn: conn, user: user} do
    subscription = subscribed(user)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    button = "#refresh-subscription-#{subscription.id}"

    view |> element(button) |> render_click()
    assert_enqueued(worker: Refresh, args: %{feed_id: subscription.feed_id})
    assert has_element?(view, "#{button}[data-refreshing][disabled]")

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)
    perform_job(Refresh, %{feed_id: subscription.feed_id})

    refute has_element?(view, "#{button}[data-refreshing]")
    assert has_element?(view, "#subscription-#{subscription.id}", "could not be reached")
  end

  # A feed checked within the last minute is not asked again.
  test "a row refreshing a source checked just now says so", %{conn: conn, user: user} do
    subscription = subscribed(user, checked_ago: 0)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#refresh-subscription-#{subscription.id}") |> render_click()
    refute_enqueued(worker: Refresh)
    refute has_element?(view, "#refresh-subscription-#{subscription.id}[data-refreshing]")
    assert render(view) =~ "This source was checked less than a minute ago."
  end

  test "a paused row offers no refresh", %{conn: conn, user: user} do
    subscription = subscribed(user)
    {:ok, _} = Library.pause(user, subscription.id, true)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    refute has_element?(view, "#refresh-subscription-#{subscription.id}")
  end

  test "refresh all queues every active source", %{conn: conn, user: user} do
    first = subscribed(user)
    paused = subscribed(user)
    {:ok, _} = Library.pause(user, paused.id, true)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#refresh-all-subscriptions") |> render_click()
    assert [%{args: %{"feed_id" => feed_id}}] = all_enqueued(worker: Refresh)
    assert feed_id == first.feed_id
    assert has_element?(view, "#refresh-subscription-#{first.id}[data-refreshing]")
  end

  test "refresh all is absent while every subscription is paused", %{conn: conn, user: user} do
    subscription = subscribed(user)
    {:ok, _} = Library.pause(user, subscription.id, true)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    refute has_element?(view, "#refresh-all-subscriptions")
  end

  test "refresh all says when every active source was checked just now", %{conn: conn, user: user} do
    subscribed(user, checked_ago: 0)
    subscribed(user, checked_ago: 0)
    {:ok, view, _} = live(conn, ~p"/subscriptions")

    view |> element("#refresh-all-subscriptions") |> render_click()
    refute_enqueued(worker: Refresh)
    assert render(view) =~ "Every active source was checked less than a minute ago."
  end

  defp subscribed(user, opts \\ [checked_ago: 120]) do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, subscription} = Library.subscribe(user, preview)
    at = DateTime.add(DateTime.utc_now(), -opts[:checked_ago], :second)

    Repo.update_all(from(f in Feed, where: f.id == ^subscription.feed_id),
      set: [last_checked_at: at]
    )

    subscription
  end
end
