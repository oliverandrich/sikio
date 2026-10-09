# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo
  alias SikioWeb.Pictures

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    podcast_url = feed_url()
    {:ok, podcast} = Parser.parse(podcast(), podcast_url)
    {:ok, sub} = Library.subscribe(user, podcast)

    {:ok, video} =
      Parser.parse(
        youtube(),
        youtube_feed_url()
      )

    {:ok, _} = Library.subscribe(user, video)
    [audio] = Enum.filter(Library.entries(user), &(&1.feed.kind == :podcast))

    %{
      conn: conn |> init_test_session(%{}) |> Gate.log_in(user),
      user: user,
      audio: audio,
      sub: sub,
      podcast_url: podcast_url
    }
  end

  # The mini player's title sends `show`. It opens the item in the current list if the list holds
  # it. Otherwise it opens the item under its feed.
  test "showing what plays keeps the list when it holds the item", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    render_hook(view, "show", %{"id" => c.audio.id})
    assert_patch(view, "/inbox/#{c.audio.id}-one-two")

    Playback.mark(c.user, c.audio.id, :heard)
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    render_hook(view, "show", %{"id" => c.audio.id})
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours/all/#{c.audio.id}-one-two")

    # After an unsubscribe the item is gone from the library, and `show` renders a notice.
    {:ok, _} = Library.unsubscribe(c.user, c.sub.id)
    {:ok, view, _} = live(c.conn, ~p"/all")
    assert render_hook(view, "show", %{"id" => c.audio.id}) =~ "no longer in your library"
  end

  # A singly saved item has no source page, so `show` opens it under all items instead.
  test "showing a saved item outside the list opens it under all items", c do
    {:ok, other} = Parser.parse(podcast("Elsewhere"), feed_url())
    {:ok, entry} = Library.save(c.user, other, hd(other.entries).external_id, :inbox)
    Playback.mark(c.user, entry.id, :heard)

    {:ok, view, _} = live(c.conn, ~p"/inbox")
    render_hook(view, "show", %{"id" => entry.id})
    assert_patch(view, "/all/#{entry.id}-one-two")
  end

  # A singly saved item offers to leave the library. An item of a followed source does not.
  test "a saved item can be removed from the library", c do
    {:ok, other} = Parser.parse(podcast("Elsewhere"), feed_url())
    {:ok, entry} = Library.save(c.user, other, hd(other.entries).external_id, :inbox)

    {:ok, view, _} = live(c.conn, "/all/#{c.audio.id}-one-two")
    refute has_element?(view, "#remove-entry")

    {:ok, view, _} = live(c.conn, "/all/#{entry.id}-one-two")
    view |> element("#remove-entry") |> render_click()
    assert_patch(view, "/all")
    refute has_element?(view, "#entries-#{entry.id}")
    assert Library.entry(c.user, entry.id) == nil
  end

  # An account that follows nothing but saved an item sees it, not the welcome for a new library.
  test "an account with only saved items lists them" do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(user)
    {:ok, other} = Parser.parse(podcast("Elsewhere"), feed_url())
    {:ok, entry} = Library.save(user, other, hd(other.entries).external_id, :inbox)

    {:ok, view, _} = live(conn, ~p"/all")
    refute has_element?(view, "#library-empty")
    assert has_element?(view, "#entries-#{entry.id}")
  end

  test "marking and changes from another tab keep filtered membership current", c do
    [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))
    Playback.mark(c.user, video.id, :heard)
    {:ok, view, _} = live(c.conn, "/inbox/#{c.audio.id}-one-two")
    view |> element("#mark-completed") |> render_click()
    refute has_element?(view, "#entries-#{c.audio.id}")
    refute has_element?(view, "#entries article")
    Playback.mark(c.user, c.audio.id, :new)
    assert has_element?(view, "#entries-#{c.audio.id}")
    {:ok, old} = Playback.start(c.user, c.audio.id)
    Playback.mark(c.user, c.audio.id, :heard)
    send(view.pid, {:playback_changed, old})
    refute has_element?(view, "#entries-#{c.audio.id}")
  end

  test "feed imports update matching entries without reloading", c do
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")

    Req.Test.stub(HTTP, fn conn ->
      xml =
        podcast("Updated source")
        |> String.replace("episode-1", "episode-2")
        |> String.replace("One &amp; two", "Brand new episode")

      Plug.Conn.send_resp(conn, 200, xml)
    end)

    assert {:ok, _} = Feeds.refresh(c.sub.feed_id)
    assert has_element?(view, "#entries article", "Brand new episode")
    assert has_element?(view, "#source-#{c.sub.feed_id}", "Updated source")
    refute has_element?(view, "#entries article", "A good video")
  end

  test "subscriptions added and removed elsewhere update the library", c do
    {:ok, view, _} = live(c.conn, ~p"/all")
    {:ok, _} = Library.unsubscribe(c.user, c.sub.id)
    refute has_element?(view, "#entries-#{c.audio.id}")
    {:ok, preview} = Parser.parse(podcast("Another source"), "https://example.org/another")
    {:ok, _} = Library.subscribe(c.user, preview)
    assert has_element?(view, "#entries article", "Another source")
  end

  # Enabling Shorts changes the list contents. Another open view reloads, as on an unsubscribe.
  test "a subscription's settings changed elsewhere update the library", c do
    {video, subscription} = short_video(c)

    {:ok, view, _} = live(c.conn, ~p"/all")
    refute has_element?(view, "#entries-#{video.id}")

    {:ok, _} = Library.configure(c.user, subscription.id, %{"shorts" => "true"}, [])
    assert has_element?(view, "#entries-#{video.id}")
  end

  test "invalid query parameters are harmless and another account cannot alter our status", c do
    # The other account subscribes to the same feed, so its playback write succeeds.
    # With a separate feed the write would fail for lack of a subscription.
    # That would test authorization, not per-account status.
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), c.podcast_url)
    Library.subscribe(other, preview)
    # An invalid feed path redirects to /inbox.
    {:ok, view, _} =
      c.conn |> live("/feeds/oops?kind=invalid") |> follow_redirect(c.conn, "/inbox")

    # The other account's write must succeed. Otherwise the status check proves nothing.
    assert {:ok, %{status: :heard}} = Playback.mark(other, c.audio.id, :heard)
    assert has_element?(view, "#entries-#{c.audio.id}", "New")
    {:ok, reloaded, _} = live(c.conn, ~p"/inbox")
    assert has_element?(reloaded, "#entries-#{c.audio.id}", "New")
  end

  # A row shows the feed name, except on that feed's own page.
  test "a row names its source except within that source", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    assert has_element?(view, "#entries-#{c.audio.id} [data-source]", "Small Hours")

    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    assert has_element?(view, "#entries-#{c.audio.id}")
    refute has_element?(view, "#entries-#{c.audio.id} [data-source]")
  end

  # /search is the phone's search tab. It lists all items and pushes `focus` to the input.
  test "search opens every item with the field ready", c do
    {:ok, view, _} = live(c.conn, ~p"/search")
    assert has_element?(view, "#search-input")
    assert_push_event(view, "focus", %{id: "search-input"})
    assert has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#entries article", "A good video")

    view |> form("#search-form", %{"q" => "video"}) |> render_change()
    assert_patch(view, "/all?q=video")
    refute has_element?(view, "#entries article", "One & two")
  end

  # Lists have no kind filter. A legacy `kind` parameter redirects away and filters nothing.
  test "no list offers a medium filter", c do
    {:ok, view, _} = c.conn |> live("/inbox?kind=video") |> follow_redirect(c.conn, "/inbox")
    refute has_element?(view, "[id^=filter-kind]")
    assert has_element?(view, "#entries article", "A good video")
    assert has_element?(view, "#entries article", "One & two")
  end

  # Each empty list shows its own message in `#list-empty`.
  test "an empty list says so in its own words", c do
    for {path, words} <- [
          {"/queue", "Nothing in the queue."},
          {"/history", "Nothing heard yet."},
          {"/feeds/#{c.sub.feed_id}-small-hours/history", "Nothing heard yet."},
          {"/all?q=nowhere", "Nothing matches “nowhere”."}
        ] do
      {:ok, view, _} = live(c.conn, path)
      refute has_element?(view, "#entries article"), path
      assert has_element?(view, "#list-empty", words), path
    end

    {:ok, view, _} = live(c.conn, ~p"/inbox")
    assert has_element?(view, "#entries article")
    refute has_element?(view, "#list-empty")

    for entry <- Library.entries(c.user), do: Sikio.Playback.mark(c.user, entry.id, :heard)
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    assert has_element?(view, "#list-empty", "You’re all caught up.")
  end

  # Only the queue has row move handles. `reorder` changes the queue order.
  test "the queue's rows move", c do
    {:ok, _} = Playback.enqueue(c.user, c.audio.id, :last)
    [video] = Library.entries(c.user, %{"status" => "inbox"})
    {:ok, _} = Playback.enqueue(c.user, video.id, :last)

    {:ok, view, _} = live(c.conn, ~p"/queue")
    assert has_element?(view, "#move-#{c.audio.id}")
    view |> element("#entries") |> render_hook("reorder", %{"id" => video.id, "index" => 0})
    assert Playback.queue(c.user) == [video.id, c.audio.id]

    {:ok, view, _} = live(c.conn, ~p"/all")
    refute has_element?(view, "#move-#{c.audio.id}")
  end

  # A feed page links the feed's website in a new tab. Other lists have no website link.
  test "a source's page opens its website", c do
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")

    assert has_element?(
             view,
             ~s|#open-website[href="#{podcast_site()}"][target="_blank"][rel~="noopener"]|
           )

    {:ok, view, _} = live(c.conn, ~p"/inbox")
    refute has_element?(view, "#open-website")
  end

  # A patch to another list closes the subscription dialog.
  test "moving to another place closes a source's dialog", c do
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    view |> element("#edit-subscription") |> render_click()
    assert has_element?(view, "#edit-subscription-confirm")

    render_patch(view, "/inbox")
    refute has_element?(view, "#edit-subscription-confirm")
  end

  # The subscription dialog sets a custom name and the delivery target.
  # The saved name replaces the feed title in the heading and the sidebar.
  test "a source is named and told where its new episodes go in its own dialog", c do
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    view |> element("#edit-subscription") |> render_click()

    assert has_element?(
             view,
             ~s|#subscription-form input[name="name"][placeholder="Small Hours"]|
           )

    assert has_element?(
             view,
             ~s|#subscription-form input[name="delivery"][value="inbox"][checked]|
           )

    view
    |> form("#subscription-form", %{"name" => "Late Night", "delivery" => "queue"})
    |> render_change()

    view |> element("#confirm-edit-subscription") |> render_click()

    assert [%{name: "Late Night", delivery: :queue}] =
             Library.subscriptions(c.user) |> Enum.filter(&(&1.id == c.sub.id))

    assert has_element?(view, "#library-heading", "Late Night")
    assert has_element?(view, "#source-#{c.sub.feed_id}", "Late Night")
  end

  # Invalid settings keep the dialog open with the error beside the field, and save no tags.
  test "a source's dialog shows why its settings were not saved", c do
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    view |> element("#edit-subscription") |> render_click()

    view
    |> form("#subscription-form", %{"name" => String.duplicate("x", 201), "new" => "Fresh"})
    |> render_submit()

    assert has_element?(view, "#subscription-name-error", "at most 200")
    assert has_element?(view, ~s|#subscription-form input[name="new"][value="Fresh"]|)
    assert Sikio.Tags.of(c.user, c.sub.id) == []
    refute render(view) =~ "Subscription not found."

    # A change to another field keeps the name's error. A change to the name clears it.
    view |> form("#subscription-form", %{"new" => "Fresher"}) |> render_change()
    assert has_element?(view, "#subscription-name-error")
    view |> form("#subscription-form", %{"name" => "Late Night"}) |> render_change()
    refute has_element?(view, "#subscription-name-error")
  end

  # Marks the setup's YouTube video as a Short. Returns it with its subscription.
  defp short_video(c) do
    [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))
    [subscription] = Enum.filter(Library.subscriptions(c.user), &(&1.feed_id == video.feed_id))
    Repo.update_all(from(e in Sikio.Feeds.Entry, where: e.id == ^video.id), set: [short: true])
    {video, subscription}
  end

  # `played_out` arrives when the detail's item ended with nothing queued after it.
  # The detail closes if the list no longer holds the item. Otherwise it stays.
  describe "an item played out with nothing after it" do
    setup c do
      {:ok, _} = Playback.enqueue(c.user, c.audio.id, :last)
      :ok
    end

    test "leaves the detail empty where the list no longer holds it", c do
      {:ok, view, _} =
        live(c.conn, SikioWeb.LibraryPaths.library_path(%{"status" => "queue"}, c.audio))

      assert has_element?(view, "#item-detail h2")
      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)

      render_hook(view, "played_out", %{"id" => to_string(c.audio.id)})
      assert_patch(view, "/queue")
    end

    test "keeps the detail where the list still holds it", c do
      {:ok, view, _} =
        live(c.conn, SikioWeb.LibraryPaths.library_path(%{"status" => ""}, c.audio))

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)

      render_hook(view, "played_out", %{"id" => to_string(c.audio.id)})
      assert has_element?(view, "#item-detail[data-entry-id='#{c.audio.id}']")
    end

    test "keeps the detail when it shows another item", c do
      {:ok, view, _} =
        live(c.conn, SikioWeb.LibraryPaths.library_path(%{"status" => "queue"}, c.audio))

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)

      render_hook(view, "played_out", %{"id" => "999999"})
      assert has_element?(view, "#item-detail[data-entry-id='#{c.audio.id}']")
    end
  end

  # Only YouTube channels have Shorts, so only their dialog has the checkbox.
  # Shorts are off by default. Enabling them lists the stored Shorts.
  test "a YouTube source's dialog shows its Shorts on request, a podcast's does not ask", c do
    {video, subscription} = short_video(c)

    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    view |> element("#edit-subscription") |> render_click()
    refute has_element?(view, ~s|#subscription-form input[name="shorts"]|)

    {:ok, view, _} = live(c.conn, "/feeds/#{video.feed_id}-good-channel")
    refute has_element?(view, "#entries-#{video.id}")
    view |> element("#edit-subscription") |> render_click()

    refute has_element?(
             view,
             ~s|#subscription-form input[name="shorts"][type="checkbox"][checked]|
           )

    view |> form("#subscription-form", %{"shorts" => "true"}) |> render_change()
    view |> element("#confirm-edit-subscription") |> render_click()

    assert [%{shorts: true}] =
             Library.subscriptions(c.user) |> Enum.filter(&(&1.id == subscription.id))

    assert has_element?(view, "#entries-#{video.id}")

    # YouTube playlists have no Shorts filter, so their dialog has no checkbox.
    playlist = "https://www.youtube.com/feeds/videos.xml?playlist_id=PLabcdefghijklmnopqrstuv"
    {:ok, preview} = Parser.parse(youtube(), playlist)
    {:ok, listed} = Library.subscribe(c.user, preview)
    {:ok, view, _} = live(c.conn, "/feeds/#{listed.feed_id}-good-channel")
    view |> element("#edit-subscription") |> render_click()
    refute has_element?(view, ~s|#subscription-form input[name="shorts"]|)
  end

  # Status filters exist only on feed pages. Elsewhere the status is the list itself.
  test "a chosen source filters by status, other places do not offer it", c do
    Playback.mark(c.user, c.audio.id, :heard)
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    refute has_element?(view, "#filter-status-heard")

    # A feed page opens on its unfinished items and marks that filter with `aria-current`.
    # A podcast's finished items are listened to.
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    assert has_element?(view, ~s|#filter-status-open[aria-current="true"]|, "Unfinished")
    assert has_element?(view, "#filter-status-heard", "Listened")
    refute has_element?(view, "#filter-kind-video")
    view |> element("#filter-status-heard") |> render_click()
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours/history")
    assert has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#source-#{c.sub.feed_id}[aria-current=page]")

    view |> element("#filter-status-open") |> render_click()
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours")
    refute has_element?(view, "#entries article", "One & two")

    view |> element("#filter-status-all") |> render_click()
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours/all")
    assert has_element?(view, "#entries article", "One & two")

    # A video's finished items are watched.
    [video] = Library.subscriptions(c.user) |> Enum.filter(&(&1.feed.kind == :youtube))
    {:ok, view, _} = live(c.conn, "/feeds/#{video.feed_id}") |> follow_redirect(c.conn)
    assert has_element?(view, "#filter-status-heard", "Watched")
  end

  # The unfinished list and the source's count hold new and started items, queued or not.
  test "a source counts and lists what is unfinished", c do
    {:ok, _} = Playback.start(c.user, c.audio.id)
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    assert has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#source-#{c.sub.feed_id}-count", ~r/^\s*1\s*$/)

    Playback.mark(c.user, c.audio.id, :archived)
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    refute has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#list-empty", "Nothing unfinished")
  end

  # Search filters the current list and the heading counts the matches. The query is in the URL.
  # `close_search` clears it. Another list starts without it.
  test "a search narrows the place and counts what it finds", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")

    view |> form("#search-form", %{q: "good"}) |> render_change()
    assert_patch(view, "/inbox?q=good")
    assert has_element?(view, "#entries article", "A good video")
    refute has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#library-count", "1 item")
    assert has_element?(view, ~s|#search-form input[value="good"]|)

    # Escape sends `close_search`. A Wallaby feature presses the key itself.
    render_hook(view, "close_search", %{})
    assert_patch(view, "/inbox")

    {:ok, view, _} = live(c.conn, ~p"/inbox?q=good")
    view |> element("#view-all") |> render_click()
    assert_patch(view, "/all")
  end

  # On reconnect LiveView resubmits every form, including the search.
  # An empty search keeps the detail open. A new query patches the URL and keeps the item.
  test "a search keeps the open item, and an unchanged one changes nothing", c do
    {:ok, view, _} = live(c.conn, item_path(c.audio))

    view |> form("#search-form", %{q: ""}) |> render_change()
    assert has_element?(view, "#item-detail h2", "One & two")

    view |> form("#search-form", %{q: "one"}) |> render_change()
    assert_patch(view, "/all/#{c.audio.id}-one-two?q=one")
  end

  # The server controls the search field's visibility. A URL with `q` opens it.
  # Emptying the input keeps it open. The toggle button hides it.
  test "the search field opens with a search and stays open while it is edited", c do
    {:ok, view, _} = live(c.conn, ~p"/all")
    assert has_element?(view, "#search-form[hidden]")

    render_hook(view, "open_search", %{})
    refute has_element?(view, "#search-form[hidden]")
    assert has_element?(view, ~s|#toggle-search[aria-expanded="true"]|)

    view |> form("#search-form", %{q: "good"}) |> render_change()
    view |> form("#search-form", %{q: ""}) |> render_change()
    refute has_element?(view, "#search-form[hidden]")

    view |> element("#toggle-search") |> render_click()
    assert has_element?(view, "#search-form[hidden]")
    assert has_element?(view, ~s|#toggle-search[aria-expanded="false"]|)

    {:ok, view, _} = live(c.conn, "/all?q=good")
    refute has_element?(view, "#search-form[hidden]")
  end

  # Switching lists drops the search query.
  test "a new place drops the filters of the last", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox?q=one")
    view |> element("#view-all") |> render_click()
    assert_patch(view, "/all")
  end

  test "removing the selected source leaves a clear empty view until another place is chosen",
       c do
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    Library.unsubscribe(c.user, c.sub.id)
    refute has_element?(view, "#entries article")
    assert has_element?(view, "#library-heading", "Unavailable source")
    view |> element("#view-all") |> render_click()
    assert has_element?(view, "#entries article", "A good video")
  end

  # Kind checks that tested only for YouTube rendered PeerTube entries as podcasts.
  # This test covers the row and the meta line.
  test "a PeerTube video is not dressed as a podcast", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)
    entry = Enum.find(Library.entries(user), &(&1.feed.kind == :peertube))

    {:ok, view, _html} = live(conn, ~p"/all")
    row = element(view, "#entries-#{entry.id}") |> render()

    assert row =~ "PeerTube", "the row names where it comes from"
    refute row =~ "Podcast"
    refute row =~ "PeerTube video", "the row says the platform, not what kind of item it is"

    {:ok, view, _page} = live(conn, item_path(entry))
    assert has_element?(view, "#playback-status", "PeerTube")
    refute has_element?(view, "#playback-status", "PeerTube video")
    refute has_element?(view, "#playback-status", "Podcast")
  end

  test "a PeerTube source says what it is in the list of sources", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)

    {:ok, view, _html} = live(conn, ~p"/subscriptions")

    # The account also subscribes to a podcast, so both labels must appear.
    assert has_element?(view, "#subscriptions article .meta-dots", "PeerTube")
    assert has_element?(view, "#subscriptions article .meta-dots", "Podcast")
  end

  # The history's calendar marks days with heard items. A day filters the list, and the
  # chip or a second click on that day removes the filter again.
  test "the history's calendar filters by a day and removes the filter", c do
    [video] = Enum.reject(Library.entries(c.user), &(&1.id == c.audio.id))
    now = DateTime.utc_now()
    today = DateTime.to_date(now)
    last_month = today |> Date.beginning_of_month() |> Date.add(-1)

    for {id, at} <- [
          {c.audio.id, now},
          {video.id, DateTime.new!(last_month, ~T[12:00:00.000000])}
        ] do
      Playback.mark(c.user, id, :heard)

      Repo.update_all(from(p in Sikio.Playback.State, where: p.entry_id == ^id),
        set: [completed_at: at]
      )
    end

    {:ok, view, _} = live(c.conn, ~p"/inbox")
    refute has_element?(view, "#toggle-calendar")

    {:ok, view, _} = live(c.conn, ~p"/history")
    assert has_element?(view, "#toggle-calendar[aria-expanded=false]")
    assert has_element?(view, "#history-calendar[hidden]")
    # A closed calendar reads no days.
    refute has_element?(view, "a#calendar-day-#{today}")

    view |> element("#toggle-calendar") |> render_click()
    assert has_element?(view, "#toggle-calendar[aria-expanded=true]")
    refute has_element?(view, "#history-calendar[hidden]")
    refute has_element?(view, "#calendar-next")
    refute has_element?(view, "a#calendar-day-#{last_month}")

    view |> element("a#calendar-day-#{today}") |> render_click()
    assert_patch(view, "/history?day=#{today}")
    assert has_element?(view, "#entries article", c.audio.title)
    refute has_element?(view, "#entries article", video.title)
    assert has_element?(view, "#library-count", "1")
    assert has_element?(view, "a#calendar-day-#{today}[aria-current=date][href='/history']")

    view |> element("#calendar-clear") |> render_click()
    assert_patch(view, "/history")
    assert has_element?(view, "#entries article", video.title)
    refute has_element?(view, "#calendar-clear")

    # Closing the calendar removes the day filter and the selection, so the history starts
    # at its top again.
    render_patch(view, "/history/#{c.audio.id}-one-two?day=#{today}")
    assert has_element?(view, "#calendar-clear[href='/history']")
    assert has_element?(view, "a#calendar-day-#{today}[href='/history']")
    view |> element("#toggle-calendar") |> render_click()
    assert_patch(view, "/history")
    assert has_element?(view, "#history-calendar[hidden]")
    refute has_element?(view, "#calendar-clear")
    assert has_element?(view, "#entries article", video.title)

    view |> element("#toggle-calendar") |> render_click()
    view |> element("#calendar-previous") |> render_click()
    assert has_element?(view, "a#calendar-day-#{last_month}")
    refute has_element?(view, "a#calendar-day-#{today}")
    view |> element("#calendar-next") |> render_click()
    assert has_element?(view, "a#calendar-day-#{today}")

    # A step other than one month back or forward changes nothing.
    render_hook(view, "calendar_month", %{"step" => "2"})
    assert has_element?(view, "a#calendar-day-#{today}")

    # A day after today opens the calendar on the current month.
    {:ok, view, _} = live(c.conn, "/history?day=#{Date.add(today, 400)}")
    assert has_element?(view, "#calendar-month", SikioWeb.DateGroups.month(today))
    refute has_element?(view, "#calendar-next")

    # An address with a day opens the calendar on that day's month.
    {:ok, view, _} = live(c.conn, "/history?day=#{last_month}")
    refute has_element?(view, "#history-calendar[hidden]")
    assert has_element?(view, "a#calendar-day-#{last_month}[aria-current=date]")
    assert has_element?(view, "#entries article", video.title)
  end

  # The double-check button archives a whole list after a confirm dialog with the count.
  # /history has no such button.
  describe "marking a list finished" do
    test "asks first, and a cancel changes nothing", c do
      {:ok, view, _} = live(c.conn, ~p"/history")
      refute has_element?(view, "#mark-all")

      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#mark-all-confirm")
      view |> element("#mark-all") |> render_click()
      assert has_element?(view, "dialog#mark-all-confirm", "2 items in this list")

      view |> element("#cancel-mark-all") |> render_click()
      refute has_element?(view, "#mark-all-confirm")
      assert Library.count(c.user, %{"status" => "completed"}) == 0
    end

    test "marks what the list shows and reads it again", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      view |> element("#mark-all") |> render_click()
      assert has_element?(view, "dialog#mark-all-confirm", "1 item in this list")

      view |> element("#confirm-mark-all") |> render_click()
      refute has_element?(view, "#mark-all-confirm")
      refute has_element?(view, "#entries article", "One & two")
      # Archived, not heard: nothing counts as completed.
      assert Library.count(c.user, %{"status" => "completed"}) == 0
      assert Library.count(c.user, %{"status" => "new"}) == 1
      refute has_element?(view, "#mark-all")
    end

    # Unchecking `in_progress` excludes started items and updates the count.
    test "may leave out what is in progress", c do
      {:ok, state} = Playback.start(c.user, c.audio.id)

      Playback.save(c.user, c.audio.id, state.session_id, %{
        "sequence" => 1,
        "position" => 30,
        "duration" => 100,
        "ended" => false
      })

      {:ok, view, _} = live(c.conn, ~p"/all")
      view |> element("#mark-all") |> render_click()
      assert has_element?(view, "dialog#mark-all-confirm", "2 items in this list")

      assert has_element?(
               view,
               ~s|#mark-all-options input[name="in_progress"][type="checkbox"][checked]|
             )

      view |> form("#mark-all-options", %{"in_progress" => "false"}) |> render_change()
      assert has_element?(view, "dialog#mark-all-confirm", "1 item in this list")

      view |> element("#confirm-mark-all") |> render_click()
      assert Library.count(c.user, %{"status" => "in_progress"}) == 1
      assert Library.count(c.user, %{"status" => "new"}) == 0
    end
  end

  # Tags are a sidebar section above the subscriptions. A tag opens as a list, like a feed.
  describe "tags" do
    test "stand above the subscriptions and open as places", c do
      {:ok, [tech]} = Sikio.Tags.set(c.user, c.sub.id, ["Tech"])

      {:ok, view, html} = live(c.conn, ~p"/inbox")
      assert html =~ ~r/id="tags-heading".*id="sources-heading"/s
      assert has_element?(view, "#tag-#{tech.id}", "Tech")
      assert has_element?(view, "#tag-#{tech.id}-count", "1")

      view |> element("#tag-#{tech.id}") |> render_click()
      assert_patch(view, "/tags/#{tech.id}-tech")
      assert has_element?(view, "#library-heading", "Tech")
      assert has_element?(view, "#entries article", "One & two")
      refute has_element?(view, "#entries article", "A good video")
      assert has_element?(view, ~s|#tag-#{tech.id}[aria-current="page"]|)
      assert has_element?(view, ~s|#filter-status-open[aria-current="true"]|)
      assert has_element?(view, "#filter-status-heard", "Listened")

      # A tag of podcasts and videos names both.
      [video] = Library.subscriptions(c.user) |> Enum.filter(&(&1.feed.kind == :youtube))
      {:ok, _} = Sikio.Tags.set(c.user, video.id, ["Tech"])
      {:ok, view, _} = live(c.conn, "/tags/#{tech.id}-tech")
      assert has_element?(view, "#filter-status-heard", "Listened & watched")
    end

    # The subscription dialog lists the account's tags as checkboxes.
    # It has an input for a new tag.
    test "are given in a source's own dialog", c do
      [video] = Library.subscriptions(c.user) |> Enum.filter(&(&1.feed.kind == :youtube))
      {:ok, _} = Sikio.Tags.set(c.user, video.id, ["Tech"])

      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#edit-subscription")

      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      view |> element("#edit-subscription") |> render_click()
      assert has_element?(view, "dialog#edit-subscription-confirm", "Small Hours")
      assert has_element?(view, ~s|#subscription-form input[type="checkbox"][value="Tech"]|)

      refute has_element?(
               view,
               ~s|#subscription-form input[type="checkbox"][value="Tech"][checked]|
             )

      view
      |> form("#subscription-form", %{"tags" => ["Tech"], "new" => "Must view"})
      |> render_change()

      view |> element("#confirm-edit-subscription") |> render_click()

      refute has_element?(view, "#edit-subscription-confirm")
      assert Enum.map(Sikio.Tags.of(c.user, c.sub.id), & &1.name) == ["Must view", "Tech"]
      assert has_element?(view, "#tags-heading")
      assert has_element?(view, "[id^=tag-]", "Must view")

      # Unchecking a tag removes it.
      view |> element("#edit-subscription") |> render_click()

      assert has_element?(
               view,
               ~s|#subscription-form input[type="checkbox"][value="Tech"][checked]|
             )

      view
      |> form("#subscription-form", %{"tags" => ["Must view"], "new" => ""})
      |> render_change()

      view |> element("#confirm-edit-subscription") |> render_click()
      assert Enum.map(Sikio.Tags.of(c.user, c.sub.id), & &1.name) == ["Must view"]

      # A second `confirm_edit_subscription` after the dialog closed changes nothing.
      view
      |> with_target("#subscription-settings")
      |> render_hook("confirm_edit_subscription", %{})

      assert Enum.map(Sikio.Tags.of(c.user, c.sub.id), & &1.name) == ["Must view"]

      # Submitting the form with Enter saves, like the confirm button.
      view |> element("#edit-subscription") |> render_click()

      view
      |> form("#subscription-form", %{"tags" => ["Must view"], "new" => "Later"})
      |> render_submit()

      refute has_element?(view, "#edit-subscription-confirm")
      assert Enum.map(Sikio.Tags.of(c.user, c.sub.id), & &1.name) == ["Later", "Must view"]
    end

    # The tag list header renames and deletes the tag. Rename rejects a name another tag has.
    test "are renamed and deleted in their own header", c do
      {:ok, [tech]} = Sikio.Tags.set(c.user, c.sub.id, ["Tech"])
      [video] = Library.subscriptions(c.user) |> Enum.filter(&(&1.feed.kind == :youtube))
      {:ok, _} = Sikio.Tags.set(c.user, video.id, ["Later"])

      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      refute has_element?(view, "#rename-tag")

      {:ok, view, _} = live(c.conn, "/tags/#{tech.id}-tech")
      view |> element("#rename-tag") |> render_click()
      assert has_element?(view, ~s|#rename-tag-form input[name="name"][value="Tech"]|)

      view |> form("#rename-tag-form", %{"name" => "later"}) |> render_submit()

      assert has_element?(
               view,
               "dialog#rename-tag-confirm",
               "Another tag is called that already."
             )

      view |> form("#rename-tag-form", %{"name" => "Technik"}) |> render_change()
      view |> element("#confirm-rename-tag") |> render_click()
      assert_patch(view, "/tags/#{tech.id}-technik")
      assert has_element?(view, "#library-heading", "Technik")
      assert has_element?(view, "#tag-#{tech.id}", "Technik")

      view |> element("#delete-tag") |> render_click()
      assert has_element?(view, "dialog#delete-tag-confirm", "Delete Technik?")
      view |> element("#confirm-delete-tag") |> render_click()
      assert_patch(view, "/queue")
      refute has_element?(view, "#tag-#{tech.id}")
      assert [_, _] = Library.subscriptions(c.user)
    end

    test "a section without tags is not shown", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#tags-heading")
    end
  end

  # Unsubscribing is offered on the feed page, after a confirm dialog that names the feed.
  describe "unsubscribing from a source" do
    test "is offered only within a source, and a cancel keeps it", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#edit-subscription")

      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      view |> element("#edit-subscription") |> render_click()
      view |> element("#unsubscribe") |> render_click()
      refute has_element?(view, "#edit-subscription-confirm")
      assert has_element?(view, "dialog#unsubscribe-confirm", "Unsubscribe from Small Hours?")

      view |> element("#cancel-unsubscribe") |> render_click()
      refute has_element?(view, "#unsubscribe-confirm")
      assert [_, _] = Library.subscriptions(c.user)
    end

    test "ends the subscription and returns to the queue", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      view |> element("#edit-subscription") |> render_click()
      view |> element("#unsubscribe") |> render_click()
      view |> element("#confirm-unsubscribe") |> render_click()

      assert_patch(view, "/queue")
      refute has_element?(view, "#source-#{c.sub.feed_id}")
      assert [%{feed: %{kind: :youtube}}] = Library.subscriptions(c.user)
    end
  end

  # A player saves progress every few seconds. A reload per sample would reload every open tab.
  # A sample without a status change updates only its row.
  # A status change can move the item between lists, so it reloads.
  # An entry inserted directly into the database shows whether a reload happened.
  describe "progress from a player" do
    setup c do
      {:ok, %{session_id: session}} = Playback.start(c.user, c.audio.id)
      {:ok, _} = Playback.save(c.user, c.audio.id, session, sample(1, 30))
      %{session: session}
    end

    test "a sample that changes no status updates the row without rereading", c do
      {:ok, view, _} = live(c.conn, ~p"/all")
      unseen = sneak_in(c)

      {:ok, _} = Playback.save(c.user, c.audio.id, c.session, sample(2, 60))

      assert has_element?(view, "#entries-#{c.audio.id}", "61 min left")
      refute has_element?(view, "#entries article", unseen)
    end

    # On /subscriptions the sidebar loads its own counts, so a reload shows in the count.
    test "a sample that changes no status leaves the sidebar's counts unread", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")
      sneak_in(c)

      {:ok, _} = Playback.save(c.user, c.audio.id, c.session, sample(2, 60))
      refute has_element?(view, "#view-inbox-count", inbox_count(c))

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)
      assert has_element?(view, "#view-inbox-count", inbox_count(c))
    end

    test "a status change rereads the list and the counts", c do
      {:ok, view, _} = live(c.conn, ~p"/all")
      unseen = sneak_in(c)

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)

      assert has_element?(view, "#entries article", unseen)
      assert has_element?(view, "#view-inbox-count", inbox_count(c))
    end
  end

  defp sample(sequence, position),
    do: %{"sequence" => sequence, "position" => position, "duration" => 3723, "ended" => false}

  # The inbox count as the sidebar computes it.
  defp inbox_count(c) do
    c.user
    |> Library.counts()
    |> Library.tally(%{}, Sikio.Tags.feeds(c.user))
    |> Map.fetch!(:inbox)
    |> to_string()
  end

  defp sneak_in(c) do
    title = "Added behind the page's back"
    insert_entries(c, [title])
    title
  end

  # Inserts with `Repo.insert_all`, so no broadcast reaches open views.
  defp insert_entries(c, titles) do
    now = DateTime.utc_now()

    rows =
      for title <- titles do
        %{
          feed_id: c.sub.feed_id,
          external_id: "direct-#{Sikio.DataCase.unique()}",
          title: title,
          published_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Sikio.Feeds.Entry, rows)
  end

  # An OPML import subscribes to up to fifty feeds, and a poll refreshes many at once.
  # Each sends `:library_changed`, so the view throttles reloads per window.
  # The test sends `:library_window_closed` instead of waiting the one-second window.
  test "a burst of new episodes rereads the library at its start and its end", c do
    {:ok, view, _} = live(c.conn, ~p"/all")

    single =
      queries_from(view, fn ->
        send(view.pid, :library_changed)
        send(view.pid, :library_window_closed)
      end)

    burst =
      queries_from(view, fn ->
        for _ <- 1..5, do: send(view.pid, :library_changed)
        send(view.pid, :library_window_closed)
      end)

    assert single > 0
    assert burst == 2 * single
  end

  # Counts the database queries the view's own process makes while `fun` runs.
  defp queries_from(view, fun) do
    {_, sql} =
      Sikio.DataCase.queries(view.pid, fn ->
        fun.()
        render(view)
      end)

    length(sql)
  end

  describe "the sidebar" do
    # / opens the queue, since listening is the main use. All items is last in the sidebar.
    test "opens on the queue and lists all items last", c do
      {:ok, view, html} = live(c.conn, ~p"/")
      assert has_element?(view, "#view-queue[aria-current=page]")

      order =
        html
        |> Floki.parse_document!()
        |> Floki.find("a[id^=view-]")
        |> Enum.map(&(Floki.attribute(&1, "id") |> hd()))
        |> Enum.reject(&String.ends_with?(&1, "-count"))

      assert order == ["view-inbox", "view-queue", "view-heard", "view-all"]
      assert has_element?(view, "#view-all[href='/all']")
      # Every item is in All items, so its count only grows. The sidebar leaves it out.
      refute has_element?(view, "#view-all-count")
      assert has_element?(view, "#view-inbox[href='/inbox']")
    end

    # The sidebar selects one list at a time and marks it with `aria-current`.
    test "chooses one place at a time and marks where the reader is", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#kind-audio")

      view |> element("#source-#{c.sub.feed_id}") |> render_click()
      assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours")
      assert has_element?(view, "#entries article", "One & two")
      refute has_element?(view, "#entries article", "A good video")
      assert has_element?(view, "#source-#{c.sub.feed_id}[aria-current=page]")
      refute has_element?(view, "#view-inbox[aria-current=page]")

      # Sidebar counts do not depend on the open list.
      assert has_element?(view, "#view-inbox-count", inbox_count(c))

      view |> element("#view-inbox") |> render_click()
      assert_patch(view, "/inbox")
    end

    test "counts new items per source and follows what the reader does", c do
      {:ok, view, _} = live(c.conn, ~p"/all")
      assert view |> element("#source-#{c.sub.feed_id}-count") |> render() =~ "1"

      view |> element("#play-#{c.audio.id}") |> render_click()
      view |> element("#mark-completed") |> render_click()

      refute has_element?(view, "#source-#{c.sub.feed_id}-count")
      assert view |> element("#view-inbox-count") |> render() =~ "1"
    end

    # The sidebar on /subscriptions updates its counts on playback changes.
    test "stays current on a page that is not the library", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")
      assert view |> element("#view-inbox-count") |> render() =~ "2"

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)

      assert view |> element("#view-inbox-count") |> render() =~ "1"
    end

    test "every member page carries it, and it leads back to the library", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")

      assert has_element?(view, "#sidebar #source-#{c.sub.feed_id}", "Small Hours")
      assert has_element?(view, ~s|#view-inbox[href="/inbox"]|)
      refute has_element?(view, "#sidebar [aria-current]:not(#manage-subscriptions)")
      assert has_element?(view, ~s|#tab-library[aria-current="page"]|)
      refute has_element?(view, ~s|#tab-inbox[aria-current="page"]|)
    end

    # The phone header has a title, an add link and, on some lists, a back link to /library.
    # List navigation lives in /library, so lists have no chips.
    test "a phone's header names where it is and leads back to the Library", c do
      for {path, title, back?} <- [
            {"/inbox", "Inbox", false},
            {"/search", "Search", false},
            {"/all?q=video", "Search", false},
            {"/all", "All items", true},
            {"/queue", "Queue", false},
            {"/history", "History", true},
            {"/feeds/#{c.sub.feed_id}-small-hours", "Small Hours", true}
          ] do
        {:ok, view, _} = live(c.conn, path)
        assert has_element?(view, ~s|#add-source[href="/add"]|), path
        assert has_element?(view, "#nav-title", title), path
        assert has_element?(view, ~s|#nav-back[href="/library"]|) == back?, path
        refute has_element?(view, "#library-chips"), path
        refute has_element?(view, "#chip-sources"), path
        refute has_element?(view, "#add-subscription"), path
      end

      {:ok, view, _} = live(c.conn, ~p"/library")
      assert has_element?(view, "#nav-title", "Library")
      refute has_element?(view, "#nav-back")
    end

    # /search is headed "Search". A search within one list keeps that list's heading.
    test "the search tab is called Search", c do
      {:ok, view, _} = live(c.conn, ~p"/search")
      assert has_element?(view, "#library-heading", "Search")
      assert has_element?(view, "#search-input[placeholder='Search in All items']")

      {:ok, view, _} = live(c.conn, ~p"/inbox?q=good")
      assert has_element?(view, "#library-heading", "Inbox")
    end

    # On a phone an item's back link leads to its list, and the item title is the large title.
    # The detail has no second back link.
    test "a phone's item leads back to its list", c do
      {:ok, view, _} = live(c.conn, "/inbox/#{c.audio.id}-one-two")
      assert has_element?(view, ~s|#nav-back[href="/inbox"]|, "Inbox")
      assert has_element?(view, "#nav-title", c.audio.title)
      assert has_element?(view, "#item-detail h2[data-large-title]")
      refute has_element?(view, "#library-heading[data-large-title]")
      refute has_element?(view, "#item-detail a", "Your library")
    end

    # The phone tab bar has four tabs and marks the current one.
    # The queue has its own tab because resuming is the most common use.
    test "a phone's tabs lead to the inbox, the queue, the library and search", c do
      for {path, tab} <- [
            {"/inbox", "inbox"},
            {"/library", "library"},
            {"/queue", "queue"},
            {"/history", "library"},
            {"/feeds/#{c.sub.feed_id}-small-hours", "library"},
            {"/search", "search"}
          ] do
        {:ok, view, _} = live(c.conn, path)
        assert has_element?(view, ~s|#tab-inbox[href="/inbox"]|)
        assert has_element?(view, ~s|#tab-queue[href="/queue"]|)
        assert has_element?(view, ~s|#tab-library[href="/library"]|)
        assert has_element?(view, ~s|#tab-search[href="/search"]|)
        assert has_element?(view, ~s|#tab-#{tab}[aria-current="page"]|), path
      end
    end

    # Adding has its own button. The sources heading is plain text.
    # The edit link beside it opens /subscriptions and is marked there.
    test "adds a source from its own button and manages the sources from a pencil", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")

      assert has_element?(view, ~s|#add-button[href="/add"]|)
      assert has_element?(view, "#sources-heading", "Subscriptions")
      refute has_element?(view, "#sources-heading a")
      refute has_element?(view, ~s|nav[aria-labelledby="sources-heading"] a[href="/add"]|)

      assert has_element?(
               view,
               ~s|#manage-subscriptions[href="/subscriptions"][aria-current="page"]|
             )

      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, ~s|#manage-subscriptions[aria-current]|)
    end

    # Invitations are rare, so they sit in the settings behind the account menu, not in the
    # main navigation. The account menu stays marked on their page.
    test "keeps invitations behind the account menu", c do
      {:ok, view, _} = live(c.conn, ~p"/invitations")

      refute has_element?(view, "#main-navigation > a[href='/invitations']")
      assert has_element?(view, "#user-menu[data-active]")
    end

    # The account menu is in the masthead, not in the main navigation.
    test "puts the account menu beside the name", c do
      {:ok, view, _} = live(c.conn, ~p"/all")

      assert has_element?(view, "#masthead #user-menu")
      refute has_element?(view, "#main-navigation #user-menu")
      assert has_element?(view, ~s|#user-menu summary[aria-label="#{c.user.username}"] svg|)
      assert has_element?(view, "#user-menu nav", c.user.username)
    end

    # A failing feed shows an icon with the error in its `title`.
    # An `sr-only` text repeats the error, since the icon alone is not announced.
    test "marks a source whose last refresh failed", c do
      Repo.update_all(
        from(f in Sikio.Feeds.Feed, where: f.id == ^c.sub.feed_id),
        set: [last_error: "invalid_feed"]
      )

      {:ok, view, _} = live(c.conn, ~p"/all")
      [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))

      assert has_element?(
               view,
               ~s|#source-#{c.sub.feed_id} [data-problem][title*="no longer serves a feed"]|
             )

      assert has_element?(view, "#source-#{c.sub.feed_id} .sr-only", "no longer serves a feed")
      refute has_element?(view, "#source-#{video.feed_id} [data-problem]")
    end

    # The detail shows the feed's image, or its initial without one, as the sidebar does.
    test "the detail shows its source's picture, or its initial without one", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours/#{c.audio.id}-one-two")
      assert has_element?(view, ~s|#item-source-mark img[src^="/pictures/"]|)

      [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))
      {:ok, view, _} = live(c.conn, "/all/#{video.id}-a-good-video")
      refute has_element?(view, "#item-source-mark img")
      assert has_element?(view, "#item-source-mark", "G")
    end

    # Sidebar feed images are proxied through `/pictures/`. A feed without one shows its initial.
    test "shows each source's picture, or its initial without one", c do
      {:ok, view, _} = live(c.conn, ~p"/all")
      [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))

      assert has_element?(view, ~s|#source-#{c.sub.feed_id} img[src^="/pictures/"]|)
      refute has_element?(view, "#source-#{video.feed_id} img")
      assert has_element?(view, "#source-#{video.feed_id} [data-initial]", "G")
      refute has_element?(view, "#user-menu summary [data-initial]")
    end
  end

  describe "a row in the list" do
    # Row images are proxied through `/pictures/`.
    # The signed reference lists the episode image, the feed image, then the kind icon.
    test "shows its picture through Sikio's own host, with the fallbacks in order", c do
      {:ok, view, _} = live(c.conn, ~p"/all")

      [src] =
        view
        |> element("#entries-#{c.audio.id} img")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("img", "src")

      assert "/pictures/" <> reference = src

      assert Pictures.verify(reference) ==
               {:ok,
                {["https://img.example.org/1.jpg", "https://img.example.org/show.jpg"],
                 "/images/kind-audio.svg"}}
    end

    test "shows the runtime the publisher stated, and none when there is none", c do
      {:ok, preview} = Parser.parse(thin_podcast(), feed_url())
      {:ok, _} = Library.subscribe(c.user, preview)
      thin = Enum.find(Library.entries(c.user), &(&1.feed_id == preview_feed_id(c.user, preview)))

      {:ok, view, _} = live(c.conn, ~p"/all")

      assert view |> element("#runtime-#{c.audio.id}") |> render() =~ "1:02:03"
      refute has_element?(view, "#runtime-#{thin.id}")
    end

    # YouTube feeds have no duration.
    # After playback the row shows the duration the player reported.
    test "a video's runtime comes from its player once it has played", c do
      [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))
      {:ok, view, _} = live(c.conn, ~p"/all")
      refute has_element?(view, "#runtime-#{video.id}")

      {:ok, %{session_id: session}} = Playback.start(c.user, video.id)

      {:ok, _} =
        Playback.save(c.user, video.id, session, %{
          "sequence" => 1,
          "position" => 30,
          "duration" => 1_234,
          "ended" => false
        })

      assert view |> element("#runtime-#{video.id}") |> render() =~ "20:34"
    end

    test "says how far somebody got, and dims what was finished", c do
      {:ok, %{session_id: session}} = Playback.start(c.user, c.audio.id)

      {:ok, _} =
        Playback.save(c.user, c.audio.id, session, %{
          "sequence" => 1,
          "position" => 1_862,
          "duration" => 3_723,
          "ended" => false
        })

      {:ok, view, _} = live(c.conn, ~p"/all")
      assert has_element?(view, ~s|#entries-#{c.audio.id} [role=progressbar][aria-valuenow="50"]|)
      # The row shows the remaining time instead of "In progress".
      assert has_element?(view, "#entries-#{c.audio.id}", "31 min left")
      refute has_element?(view, "#entries-#{c.audio.id}", "In progress")
      # Marking happens in the detail or with m, so rows have no buttons.
      refute has_element?(view, "#entries-#{c.audio.id} button")

      # In its last minute the item counts as heard, and the row drops the progress bar.
      {:ok, _} =
        Playback.save(c.user, c.audio.id, session, %{
          "sequence" => 2,
          "position" => 3_700,
          "duration" => nil,
          "ended" => false
        })

      assert has_element?(view, ~s|#entries-#{c.audio.id}[data-status="heard"]|)
      refute has_element?(view, "#entries-#{c.audio.id} [role=progressbar]")
    end
  end

  describe "the heading" do
    # The list loads in batches of 25. The heading counts all matching items, not the loaded ones.
    test "counts every matching item, however many are loaded", c do
      insert_entries(c, for(n <- 1..120, do: "Bulk #{n}"))
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")

      assert view |> element("#library-count") |> render() =~ "121 items"
    end
  end

  # Date headings group items by publication date.
  describe "date groups" do
    defp headings(view) do
      view
      |> element("#entries")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("[data-group]")
      |> Enum.map(&String.trim(Floki.text(&1)))
    end

    test "a list is grouped by when its items were published", c do
      now = DateTime.utc_now()

      Repo.insert_all(Sikio.Feeds.Entry, [
        %{
          feed_id: c.sub.feed_id,
          external_id: "fresh",
          title: "Fresh",
          published_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          feed_id: c.sub.feed_id,
          external_id: "old",
          title: "Old",
          published_at: ~U[2025-12-24 12:00:00.000000Z],
          inserted_at: now,
          updated_at: now
        }
      ])

      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours/all")
      assert ["Today" | _] = headings(view)
      assert List.last(headings(view)) == "December 2025"
      assert headings(view) == Enum.uniq(headings(view))
      refute has_element?(view, "#entries article[data-group]")
    end

    # The queue uses manual order, so date headings do not apply.
    test "the queue has no date groups", c do
      {:ok, _} = Playback.start(c.user, c.audio.id)
      {:ok, view, _} = live(c.conn, ~p"/queue")
      assert has_element?(view, "#entries article", "One & two")
      assert headings(view) == []
    end
  end

  # The list loads 25 items and the next batch when its end scrolls into view.
  describe "the list grows" do
    setup c do
      insert_entries(c, for(n <- 1..40, do: "Bulk #{n}"))
      :ok
    end

    test "by a batch when its end comes into view", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      assert length(rows(view)) == 25

      render_hook(view, "load_more", %{})
      assert length(rows(view)) == 41
    end

    test "when j moves past the last entry loaded", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      last = view |> rows() |> List.last() |> String.replace_prefix("entries-", "")

      {:ok, view, _} = live(c.conn, href(view, last))
      render_hook(view, "move", %{"key" => "j"})

      assert length(rows(view)) == 41
      assert_patch(view)
    end

    # An item opened by URL can lie beyond the first batch.
    # The list loads up to it, marks it, and j moves to the next item.
    test "far enough to show an item opened by its address", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      render_hook(view, "load_more", %{})
      ids = rows(view)
      fortieth = ids |> Enum.at(39) |> String.replace_prefix("entries-", "")
      after_it = ids |> Enum.at(40) |> String.replace_prefix("entries-", "")
      next = href(view, after_it)
      assert next =~ ~r|^/feeds/#{c.sub.feed_id}-small-hours/#{after_it}-|

      {:ok, view, _} = live(c.conn, href(view, fortieth))
      assert has_element?(view, ~s|#play-#{fortieth}[aria-current="true"]|)

      render_hook(view, "move", %{"key" => "j"})
      assert_patch(view, next)
    end

    # A reload keeps the loaded length. Otherwise the list would shrink under the scroll position.
    test "and keeps its length when it is read again", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      render_hook(view, "load_more", %{})
      send(view.pid, :library_window_closed)
      send(view.pid, :library_changed)
      assert length(rows(view)) == 41
    end
  end

  # An item opened by its address deep in a list loads with a window of rows around it, not
  # with every row above it. The window grows upwards by a batch when its top comes into view.
  describe "an item deep in a list" do
    setup c do
      insert_entries(c, for(n <- 1..100, do: "Bulk #{n}"))
      bottom = Repo.one!(from e in Sikio.Feeds.Entry, where: e.title == "Bulk 1")
      newest = Repo.one!(from e in Sikio.Feeds.Entry, where: e.title == "Bulk 100")
      %{bottom: bottom, newest: newest, path: "/feeds/#{c.sub.feed_id}-small-hours"}
    end

    test "loads a window around it", c do
      {:ok, view, _} = live(c.conn, "#{c.path}/#{c.bottom.id}-bulk-1")
      assert has_element?(view, ~s|#play-#{c.bottom.id}[aria-current="true"]|)
      assert length(rows(view)) <= 51
      refute has_element?(view, "#entries-#{c.newest.id}")
      # The date group continues above the window, so its heading waits there. A heading on
      # top would stay first after the batch above loads, and the list would jump to it.
      refute has_element?(view, "#entries > :first-child[data-group]")

      before = length(rows(view))
      render_hook(view, "load_less", %{})
      assert length(rows(view)) == before + 25
      refute has_element?(view, "#entries-#{c.newest.id}")

      render_hook(view, "load_less", %{})
      render_hook(view, "load_less", %{})
      render_hook(view, "load_less", %{})
      assert has_element?(view, "#entries-#{c.newest.id}")
      refute has_element?(view, "#entries[phx-viewport-top]")
    end

    test "loads the batch above when k moves past the window's first row", c do
      {:ok, view, _} = live(c.conn, "#{c.path}/#{c.bottom.id}-bulk-1")
      first = view |> rows() |> hd() |> String.replace_prefix("entries-", "")
      render_patch(view, href(view, first))
      before = length(rows(view))

      render_hook(view, "move", %{"key" => "k"})
      assert length(rows(view)) == before + 25
      above = view |> rows() |> Enum.at(24) |> String.replace_prefix("entries-", "")
      assert_patch(view, href(view, above))
    end

    # Dragging and arrow keys send a row's index in the list as its queue position.
    # So the queue loads every row above an item, as the indexes would otherwise shift.
    test "in the queue loads every row above it", c do
      for n <- 40..1//-1 do
        id = Repo.one!(from e in Sikio.Feeds.Entry, where: e.title == ^"Bulk #{n}", select: e.id)
        {:ok, _} = Playback.enqueue(c.user, id, :last)
      end

      {:ok, view, _} = live(c.conn, "/queue/#{c.bottom.id}-bulk-1")
      assert has_element?(view, ~s|#play-#{c.bottom.id}[aria-current="true"]|)
      assert length(rows(view)) == 40
      refute has_element?(view, "#entries[phx-viewport-top]")
    end

    # A reload keeps the window. Otherwise the list would jump to its top under the reader.
    test "keeps its window when the list is read again", c do
      {:ok, view, _} = live(c.conn, "#{c.path}/#{c.bottom.id}-bulk-1")
      shown = rows(view)
      send(view.pid, :library_window_closed)
      send(view.pid, :library_changed)
      assert rows(view) == shown
    end
  end

  defp rows(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#entries article")
    |> Floki.attribute("id")
  end

  defp preview_feed_id(user, preview) do
    Enum.find_value(Library.subscriptions(user), &(&1.feed.url == preview.url && &1.feed_id))
  end

  # Returns the `href` of a row's link.
  defp href(view, id) do
    view
    |> element("#play-#{id}")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("href")
    |> hd()
  end
end
