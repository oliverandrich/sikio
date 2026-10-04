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

  # The mini player's title shows what plays in the list on screen, or else in its source.
  test "showing what plays keeps the list when it holds the item", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    render_hook(view, "show", %{"id" => c.audio.id})
    assert_patch(view, "/inbox/#{c.audio.id}-one-two")

    Playback.mark(c.user, c.audio.id, :heard)
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    render_hook(view, "show", %{"id" => c.audio.id})
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours/all/#{c.audio.id}-one-two")

    # What plays may have left the library, its source removed meanwhile. The page says so.
    {:ok, _} = Library.unsubscribe(c.user, c.sub.id)
    {:ok, view, _} = live(c.conn, ~p"/all")
    assert render_hook(view, "show", %{"id" => c.audio.id}) =~ "no longer in your library"
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

  test "invalid query parameters are harmless and another account cannot alter our status", c do
    # The same source on purpose: a co-subscriber may write playback, and what this asks is that
    # writing it leaves our own status alone. Give them a feed of their own and the write is
    # refused for want of a subscription, which proves something else entirely.
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), c.podcast_url)
    Library.subscribe(other, preview)
    # Nonsense in an address is set right, here to the library's front.
    {:ok, view, _} =
      c.conn |> live("/feeds/oops?kind=invalid") |> follow_redirect(c.conn, "/inbox")

    # Both halves matter. Their write has to land, or this proves only that a stranger cannot
    # write, which is a different test and one that passes for the wrong reason.
    assert {:ok, %{status: :heard}} = Playback.mark(other, c.audio.id, :heard)
    assert has_element?(view, "#entries-#{c.audio.id}", "New")
    {:ok, reloaded, _} = live(c.conn, ~p"/inbox")
    assert has_element?(reloaded, "#entries-#{c.audio.id}", "New")
  end

  # Within its own source a row does not repeat the source's name; everywhere else it names it.
  test "a row names its source except within that source", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    assert has_element?(view, "#entries-#{c.audio.id} [data-source]", "Small Hours")

    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    assert has_element?(view, "#entries-#{c.audio.id}")
    refute has_element?(view, "#entries-#{c.audio.id} [data-source]")
  end

  # Search is a place of its own on a phone: every item, with the field open and taking the keys.
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

  # No list is narrowed by medium. An old address that names one is set right and narrows nothing.
  test "no list offers a medium filter", c do
    {:ok, view, _} = c.conn |> live("/inbox?kind=video") |> follow_redirect(c.conn, "/inbox")
    refute has_element?(view, "[id^=filter-kind]")
    assert has_element?(view, "#entries article", "A good video")
    assert has_element?(view, "#entries article", "One & two")
  end

  # An empty list says what it would hold, in a word fitting the place, and gives no advice.
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

  # The queue's head says whether the player goes on with it, and the reader turns that off and on.
  # Only the queue offers it, and only the queue's rows carry a handle to move them.
  test "the queue plays on unless told not to, and its rows move", c do
    {:ok, _} = Playback.enqueue(c.user, c.audio.id, :last)
    [video] = Library.entries(c.user, %{"status" => "inbox"})
    {:ok, _} = Playback.enqueue(c.user, video.id, :last)

    {:ok, view, _} = live(c.conn, ~p"/queue")
    assert has_element?(view, ~s|#play-on[aria-pressed="true"]|)
    view |> element("#play-on") |> render_click()
    assert has_element?(view, ~s|#play-on[aria-pressed="false"]|)
    refute Playback.play_on?(c.user)

    assert has_element?(view, "#move-#{c.audio.id}")
    view |> element("#entries") |> render_hook("reorder", %{"id" => video.id, "index" => 0})
    assert Playback.queue(c.user) == [video.id, c.audio.id]

    {:ok, view, _} = live(c.conn, ~p"/all")
    refute has_element?(view, "#play-on")
    refute has_element?(view, "#move-#{c.audio.id}")
  end

  # A source's own dialog gives it a name of the reader's own and says where its new episodes go.
  # The name stands wherever the source is named.
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

  # Within a source the statuses are a filter; elsewhere they are the place itself.
  test "a chosen source filters by status, other places do not offer it", c do
    Playback.mark(c.user, c.audio.id, :heard)
    {:ok, view, _} = live(c.conn, ~p"/inbox")
    refute has_element?(view, "#filter-status-heard")

    # A source opens on what is new in it, and says so.
    {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
    assert has_element?(view, ~s|#filter-status-inbox[aria-current="true"]|)
    refute has_element?(view, "#filter-kind-video")
    view |> element("#filter-status-heard") |> render_click()
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours/history")
    assert has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#source-#{c.sub.feed_id}[aria-current=page]")

    view |> element("#filter-status-inbox") |> render_click()
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours")
    refute has_element?(view, "#entries article", "One & two")

    view |> element("#filter-status-all") |> render_click()
    assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours/all")
    assert has_element?(view, "#entries article", "One & two")
  end

  # The magnifier opens a field that searches the place as it is filtered. What was typed is in
  # the address; Escape clears it, and another place starts without it.
  test "a search narrows the place and counts what it finds", c do
    {:ok, view, _} = live(c.conn, ~p"/inbox")

    view |> form("#search-form", %{q: "good"}) |> render_change()
    assert_patch(view, "/inbox?q=good")
    assert has_element?(view, "#entries article", "A good video")
    refute has_element?(view, "#entries article", "One & two")
    assert has_element?(view, "#library-count", "1 item")
    assert has_element?(view, ~s|#search-form input[value="good"]|)

    # Escape in the field sends this; the browser test presses the key itself.
    render_hook(view, "close_search", %{})
    assert_patch(view, "/inbox")

    {:ok, view, _} = live(c.conn, ~p"/inbox?q=good")
    view |> element("#view-all") |> render_click()
    assert_patch(view, "/all")
  end

  # After a reconnect the browser sends every form again, the search with it. An unchanged search
  # leaves the address alone, and a search keeps the item that is open.
  test "a search keeps the open item, and an unchanged one changes nothing", c do
    {:ok, view, _} = live(c.conn, item_path(c.audio))

    view |> form("#search-form", %{q: ""}) |> render_change()
    assert has_element?(view, "#item-detail h2", "One & two")

    view |> form("#search-form", %{q: "one"}) |> render_change()
    assert_patch(view, "/all/#{c.audio.id}-one-two?q=one")
  end

  # Whether the field is open is the page's to say: an address with a search shows it, emptying it
  # keeps it open, and only the magnifier or Escape folds it away again.
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

  # Choosing another place starts it unfiltered.
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

  # A third kind arrived and the interface still asked whether something was YouTube. Everything
  # that is not answered that way fell to the podcast side, so a PeerTube video was drawn with a
  # microphone and described as audio from a publisher.
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

    {:ok, _view, html} = live(conn, ~p"/subscriptions")

    # The account also follows a podcast, so both words have to be there, each on its own source.
    assert html =~ "PeerTube ·"
    assert html =~ "Podcast ·"
  end

  # A playing item saves its place every few seconds. Rereading the library each time would cost
  # every open tab a reload, so a sample that changes no status updates the one row; a status
  # change may move the item between views and reloads. An entry added behind the page's back
  # shows which of the two happened.
  # The double check marks a whole list finished, after a question that names how many. A list
  # of finished items has nothing to offer it.
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
      # Put aside, not heard: none of it counts as finished.
      assert Library.count(c.user, %{"status" => "completed"}) == 0
      assert Library.count(c.user, %{"status" => "new"}) == 1
      # An empty list has nothing left to mark.
      refute has_element?(view, "#mark-all")
    end

    # Unticked, what is in progress stays, and the question counts again.
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

  # Tags are a section of their own above the subscriptions. A tag is a place like a source.
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
      assert has_element?(view, ~s|#filter-status-inbox[aria-current="true"]|)
    end

    # A source's own dialog gives it tags: the account's tags to tick, and a field for a new one.
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

      # Unticked, a tag comes off again.
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

      # A second press after the dialog has closed changes nothing.
      render_hook(view, "confirm_edit_subscription", %{})
      assert Enum.map(Sikio.Tags.of(c.user, c.sub.id), & &1.name) == ["Must view"]

      # Enter in the field saves, as the button does.
      view |> element("#edit-subscription") |> render_click()

      view
      |> form("#subscription-form", %{"tags" => ["Must view"], "new" => "Later"})
      |> render_submit()

      refute has_element?(view, "#edit-subscription-confirm")
      assert Enum.map(Sikio.Tags.of(c.user, c.sub.id), & &1.name) == ["Later", "Must view"]
    end

    # A tag's own header renames it, refusing a name another tag holds, and deletes it.
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
      assert_patch(view, "/inbox")
      refute has_element?(view, "#tag-#{tech.id}")
      assert [_, _] = Library.subscriptions(c.user)
    end

    test "a section without tags is not shown", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#tags-heading")
    end
  end

  # A source can be left where it is read, after a question that names it.
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

    test "ends the subscription and returns to what is new", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      view |> element("#edit-subscription") |> render_click()
      view |> element("#unsubscribe") |> render_click()
      view |> element("#confirm-unsubscribe") |> render_click()

      assert_patch(view, "/inbox")
      refute has_element?(view, "#source-#{c.sub.feed_id}")
      assert [%{feed: %{kind: :youtube}}] = Library.subscriptions(c.user)
    end
  end

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

    # Away from the library the sidebar counts for itself, so this is where a reread would show.
    test "a sample that changes no status leaves the sidebar's counts unread", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")
      sneak_in(c)

      {:ok, _} = Playback.save(c.user, c.audio.id, c.session, sample(2, 60))
      refute has_element?(view, "#view-all-count", "3")

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)
      assert has_element?(view, "#view-all-count", "3")
    end

    test "a status change rereads the list and the counts", c do
      {:ok, view, _} = live(c.conn, ~p"/all")
      unseen = sneak_in(c)

      {:ok, _} = Playback.mark(c.user, c.audio.id, :heard)

      assert has_element?(view, "#entries article", unseen)
      assert has_element?(view, "#view-all-count", "3")
    end
  end

  defp sample(sequence, position),
    do: %{"sequence" => sequence, "position" => position, "duration" => 3723, "ended" => false}

  defp sneak_in(c) do
    title = "Added behind the page's back"
    insert_entries(c, [title])
    title
  end

  # Written straight to the database, so no open view hears of them.
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

  # An import subscribes to up to fifty sources in a row, and a poll refreshes many feeds at
  # once. Each sends an event, and every open tab would reread the library for each of them.
  # The test closes the window itself rather than waiting the second it lasts.
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
    # New is where the library opens, at its front and after signing in. All items come last.
    test "opens on new and lists all items last", c do
      {:ok, view, html} = live(c.conn, ~p"/")
      assert has_element?(view, "#view-inbox[aria-current=page]")

      order =
        html
        |> Floki.parse_document!()
        |> Floki.find("a[id^=view-]")
        |> Enum.map(&(Floki.attribute(&1, "id") |> hd()))
        |> Enum.reject(&String.ends_with?(&1, "-count"))

      assert order == ["view-inbox", "view-queue", "view-heard", "view-all"]
      assert has_element?(view, "#view-all[href='/all']")
      assert has_element?(view, "#view-inbox[href='/inbox']")
    end

    # The sidebar is where the reader is, not a set of filters: one entry at a time.
    test "chooses one place at a time and marks where the reader is", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      refute has_element?(view, "#kind-audio")

      view |> element("#source-#{c.sub.feed_id}") |> render_click()
      assert_patch(view, "/feeds/#{c.sub.feed_id}-small-hours")
      assert has_element?(view, "#entries article", "One & two")
      refute has_element?(view, "#entries article", "A good video")
      assert has_element?(view, "#source-#{c.sub.feed_id}[aria-current=page]")
      refute has_element?(view, "#view-inbox[aria-current=page]")

      # A count says what is in that place, whichever place is open.
      assert view |> element("#view-all-count") |> render() =~ "2"

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

    # A page that is not the library still follows what happens elsewhere.
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
      refute has_element?(view, "#sidebar [aria-current]:not(#subscriptions-heading)")
      assert has_element?(view, ~s|#tab-library[aria-current="page"]|)
      refute has_element?(view, ~s|#tab-inbox[aria-current="page"]|)
    end

    # A phone's header is a slim bar: the name or the way back to the Library, the title once the
    # large one has scrolled away, and adding a source and the account at its right. The places
    # are the Library's, so the list's own head has no chips.
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
        assert has_element?(view, ~s|#add-source[href="/subscriptions"]|), path
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

    # The Search tab is named for what it does. A search within one place keeps that place's name.
    test "the search tab is called Search", c do
      {:ok, view, _} = live(c.conn, ~p"/search")
      assert has_element?(view, "#library-heading", "Search")
      assert has_element?(view, "#search-input[placeholder='Search in All items']")

      {:ok, view, _} = live(c.conn, ~p"/inbox?q=good")
      assert has_element?(view, "#library-heading", "Inbox")
    end

    # An item leads back to the list it was opened from and names itself once its title has
    # scrolled away. The bar's way back is its only one.
    test "a phone's item leads back to its list", c do
      {:ok, view, _} = live(c.conn, "/inbox/#{c.audio.id}-one-two")
      assert has_element?(view, ~s|#nav-back[href="/inbox"]|, "Inbox")
      assert has_element?(view, "#nav-title", c.audio.title)
      assert has_element?(view, "#item-detail h2[data-large-title]")
      refute has_element?(view, "#library-heading[data-large-title]")
      refute has_element?(view, "#item-detail a", "Your library")
    end

    # A phone moves between four tabs, and the one it is in is marked. What is in progress has a
    # tab of its own, because going on with it is what a reader most often comes for.
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

    # The heading over the sources is where they are managed, so it leads there and says when
    # the reader is there.
    test "names the sources as subscriptions and leads to managing them", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")

      assert has_element?(
               view,
               ~s|#sources-heading a#subscriptions-heading[href="/subscriptions"][aria-current="page"]|,
               "Subscriptions"
             )
    end

    # Inviting is done now and then, so it sits in the account's menu rather than among the
    # places a reader moves between, on a phone as on a desktop.
    test "keeps invitations in the account menu", c do
      {:ok, view, _} = live(c.conn, ~p"/invitations")

      refute has_element?(view, "#main-navigation > a[href='/invitations']")
      assert has_element?(view, ~s|#user-menu a[href="/invitations"][aria-current="page"]|)
      assert has_element?(view, "#user-menu[data-active]")
    end

    # The account sits beside the name at the top, on a phone as on a desktop. The bar at the
    # foot holds the places a reader moves between.
    test "puts the account menu beside the name", c do
      {:ok, view, _} = live(c.conn, ~p"/all")

      assert has_element?(view, "#masthead #user-menu")
      refute has_element?(view, "#main-navigation #user-menu")
      assert has_element?(view, ~s|#user-menu summary[aria-label="#{c.user.username}"] svg|)
      assert has_element?(view, "#user-menu nav", c.user.username)
    end

    # A source whose last refresh failed says so beside its name, and what went wrong on hover.
    # The words are there for a screen reader too; a flash of lightning alone says nothing.
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

    # The detail names its source as the sidebar does: by its picture, or its initial without one.
    test "the detail shows its source's picture, or its initial without one", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours/#{c.audio.id}-one-two")
      assert has_element?(view, ~s|#item-source-mark img[src^="/pictures/"]|)

      [video] = Enum.filter(Library.entries(c.user), &(&1.feed.kind == :youtube))
      {:ok, view, _} = live(c.conn, "/all/#{video.id}-a-good-video")
      refute has_element?(view, "#item-source-mark img")
      assert has_element?(view, "#item-source-mark", "G")
    end

    # A source is recognised by its picture, through this host like every other. A source that
    # names none shows its first letter.
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
    # The picture comes from this host. Its address names the episode's own picture first, then
    # the show's, then the mark for what kind of thing it is.
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

    # YouTube's feed states no length. Once the player has seen it, the row shows the one it
    # reported, for this account alone.
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
      # The time left says more than a word for having started.
      assert has_element?(view, "#entries-#{c.audio.id}", "31 min left")
      refute has_element?(view, "#entries-#{c.audio.id}", "In progress")
      # Marking happens in the detail or with m, so the row carries no buttons of its own.
      refute has_element?(view, "#entries-#{c.audio.id} button")

      # Past 90 % of its length it counts as heard, and the row says so instead of a bar.
      {:ok, _} =
        Playback.save(c.user, c.audio.id, session, %{
          "sequence" => 2,
          "position" => 3_400,
          "duration" => nil,
          "ended" => false
        })

      assert has_element?(view, ~s|#entries-#{c.audio.id}[data-status="heard"]|)
      refute has_element?(view, "#entries-#{c.audio.id} [role=progressbar]")
    end
  end

  describe "the heading" do
    # The list stops at a hundred. The heading says how many there are, not how many fit.
    test "counts every matching item, however many are loaded", c do
      insert_entries(c, for(n <- 1..120, do: "Bulk #{n}"))
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")

      assert view |> element("#library-count") |> render() =~ "121 items"
    end
  end

  # The list loads enough for a screen and the next batch as its end comes into view. There are
  # no pages to turn.
  # Headings name when the items below them happened, in the order the list runs: when they
  # were published, or for what is in progress when it was last played.
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

    # The queue runs by the reader's own order, which no date divides.
    test "the queue has no date groups", c do
      {:ok, _} = Playback.start(c.user, c.audio.id)
      {:ok, view, _} = live(c.conn, ~p"/queue")
      assert has_element?(view, "#entries article", "One & two")
      assert headings(view) == []
    end
  end

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

    # An item opened by its address may lie beyond the first batch. The list loads up to it, so
    # it is marked in place and j goes on to the one after it.
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

    # An update rereads the list. It keeps what was loaded, or the list would shrink under the
    # reader's scroll.
    test "and keeps its length when it is read again", c do
      {:ok, view, _} = live(c.conn, "/feeds/#{c.sub.feed_id}-small-hours")
      render_hook(view, "load_more", %{})
      send(view.pid, :library_window_closed)
      send(view.pid, :library_changed)
      assert length(rows(view)) == 41
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

  # The address a row in the list leads to.
  defp href(view, id) do
    view
    |> element("#play-#{id}")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("href")
    |> hd()
  end
end
