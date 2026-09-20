defmodule SikioWeb.LibraryLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

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

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    {:ok, podcast} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, sub} = Library.subscribe(user, podcast)

    {:ok, video} =
      Parser.parse(
        youtube(),
        "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
      )

    {:ok, _} = Library.subscribe(user, video)
    [audio] = Enum.filter(Library.entries(user), &(&1.feed.kind == :podcast))

    %{
      conn: conn |> init_test_session(%{}) |> Gate.log_in(user),
      user: user,
      audio: audio,
      sub: sub
    }
  end

  test "filters combine, survive reload and reset through the form", c do
    Playback.mark(c.user, c.audio.id, :completed)
    {:ok, view, _} = live(c.conn, ~p"/")

    view
    |> form("#library-filters",
      filters: %{kind: "podcast", status: "completed", source: to_string(c.sub.feed_id)}
    )
    |> render_change()

    path = assert_patch(view)
    assert has_element?(view, "#entries article", "One & two")
    refute has_element?(view, "#entries article", "A good video")
    {:ok, reloaded, _} = live(c.conn, path)
    assert has_element?(reloaded, "#entries article", "One & two")
    refute has_element?(reloaded, "#entries article", "A good video")
    reloaded |> element("#clear-filters") |> render_click()
    assert_patch(reloaded, "/")
    assert has_element?(reloaded, "#entries article", "A good video")
  end

  test "marking and changes from another tab keep filtered membership current", c do
    {:ok, view, _} = live(c.conn, ~p"/?kind=podcast&status=new")
    view |> element("#complete-#{c.audio.id}") |> render_click()
    refute has_element?(view, "#entries-#{c.audio.id}")
    assert has_element?(view, "#library-no-matches")
    Playback.mark(c.user, c.audio.id, :new)
    assert has_element?(view, "#entries-#{c.audio.id}")
    {:ok, old} = Playback.start(c.user, c.audio.id)
    Playback.mark(c.user, c.audio.id, :completed)
    send(view.pid, {:playback_changed, old})
    refute has_element?(view, "#entries-#{c.audio.id}")
  end

  test "feed imports update matching entries without reloading", c do
    {:ok, view, _} = live(c.conn, ~p"/?kind=podcast&status=new")

    Req.Test.stub(HTTP, fn conn ->
      xml =
        podcast("Updated source")
        |> String.replace("episode-1", "episode-2")
        |> String.replace("One &amp; two", "Brand new episode")

      Plug.Conn.send_resp(conn, 200, xml)
    end)

    assert {:ok, _} = Feeds.refresh(c.sub.feed_id)
    assert has_element?(view, "#entries article", "Brand new episode")
    assert has_element?(view, "#filter-source option", "Updated source")
    refute has_element?(view, "#entries article", "A good video")
  end

  test "subscriptions added and removed elsewhere update the library", c do
    {:ok, view, _} = live(c.conn, ~p"/")
    {:ok, _} = Library.unsubscribe(c.user, c.sub.id)
    refute has_element?(view, "#entries-#{c.audio.id}")
    {:ok, preview} = Parser.parse(podcast("Another source"), "https://example.org/another")
    {:ok, _} = Library.subscribe(c.user, preview)
    assert has_element?(view, "#entries article", "Another source")
  end

  test "invalid query parameters are harmless and another account cannot alter our status", c do
    other = Repo.insert!(User.changeset(%User{}, %{username: "other"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    Library.subscribe(other, preview)
    {:ok, view, _} = live(c.conn, ~p"/?kind=invalid&status=invalid&source=oops")
    Playback.mark(other, c.audio.id, :completed)
    assert has_element?(view, "#entries-#{c.audio.id}", "New")
    {:ok, reloaded, _} = live(c.conn, ~p"/?status=new")
    assert has_element?(reloaded, "#entries-#{c.audio.id}", "New")
  end

  test "removing the selected source leaves a clear empty view until filters are cleared", c do
    {:ok, view, _} = live(c.conn, ~p"/?source=#{c.sub.feed_id}")
    Library.unsubscribe(c.user, c.sub.id)
    assert has_element?(view, "#library-no-matches")
    assert has_element?(view, "#filter-source option[selected]", "Unavailable source")
    view |> element("#clear-filters") |> render_click()
    assert has_element?(view, "#entries article", "A good video")
  end

  # A third kind arrived and the interface still asked whether something was YouTube. Everything
  # that is not answered that way fell to the podcast side, so a PeerTube video was drawn with a
  # microphone and described as audio from a publisher.
  test "a PeerTube video is not dressed as a podcast", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(peertube(), "https://video.example.org/feeds/videos.xml")
    {:ok, _} = Library.subscribe(user, preview)
    entry = Enum.find(Library.entries(user), &(&1.feed.kind == :peertube))

    {:ok, view, _html} = live(conn, ~p"/")
    row = element(view, "#entries-#{entry.id}") |> render()

    assert row =~ "lucide-circle-play", "it is watched, so it carries the mark of a video"
    refute row =~ "lucide-mic"

    {:ok, _view, page} = live(conn, ~p"/library/#{entry.id}")
    refute page =~ "YouTube receives your connection data"
    refute page =~ "Audio streams directly from the podcast publisher"
    assert page =~ "video.example.org"
  end
end
