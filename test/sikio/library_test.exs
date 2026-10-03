# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.LibraryTest do
  @moduledoc false
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback

  setup do
    alice = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    %{alice: alice, bob: bob, preview: preview}
  end

  test "subscribes once, imports episodes and isolates accounts", ctx do
    assert {:ok, subscription} = Library.subscribe(ctx.alice, ctx.preview)
    assert {:ok, duplicate} = Library.subscribe(ctx.alice, ctx.preview)
    assert duplicate.id == subscription.id
    assert [%{feed: %{title: "Small Hours"}}] = Library.subscriptions(ctx.alice)
    assert [%{title: "One & two"}] = Library.entries(ctx.alice)
    assert Library.subscriptions(ctx.bob) == []
    assert Library.entries(ctx.bob) == []
  end

  # The mini player's title shows what plays in the list on screen when that list holds it.
  test "says whether a list holds an entry, for the account alone", ctx do
    {:ok, _} = Library.subscribe(ctx.alice, ctx.preview)
    [entry] = Library.entries(ctx.alice)

    assert Library.listed?(ctx.alice, %{"status" => "new"}, entry.id)
    refute Library.listed?(ctx.alice, %{"status" => "completed"}, entry.id)
    refute Library.listed?(ctx.bob, %{}, entry.id)
    refute Library.listed?(ctx.alice, %{}, "nonsense")
  end

  test "pause and removal only affect the owning account", ctx do
    {:ok, ours} = Library.subscribe(ctx.alice, ctx.preview)
    {:ok, theirs} = Library.subscribe(ctx.bob, ctx.preview)
    assert {:error, :not_found} = Library.pause(ctx.bob, ours.id, true)
    assert {:error, :not_found} = Library.unsubscribe(ctx.bob, ours.id)
    assert {:ok, %{paused: true}} = Library.pause(ctx.alice, ours.id, true)
    assert [%{id: id, paused: false}] = Library.subscriptions(ctx.bob)
    assert id == theirs.id
    assert {:ok, _} = Library.unsubscribe(ctx.alice, ours.id)
    assert Library.entries(ctx.alice) == []
    assert length(Library.entries(ctx.bob)) == 1
  end

  test "filters status, media and source independently and together within the account", ctx do
    {:ok, sub} = Library.subscribe(ctx.alice, ctx.preview)
    [audio] = Library.entries(ctx.alice)

    {:ok, video} =
      Parser.parse(
        youtube(),
        youtube_feed_url()
      )

    Library.subscribe(ctx.alice, video)
    Library.subscribe(ctx.bob, ctx.preview)
    Playback.mark(ctx.bob, audio.id, :completed)
    assert length(Library.entries(ctx.alice, %{"status" => "new"})) == 2
    assert Library.entries(ctx.alice, %{"status" => "completed"}) == []
    assert [item] = Library.entries(ctx.alice, %{"source" => to_string(sub.feed_id)})
    assert item.id == audio.id
    assert [%{feed: %{kind: :youtube}}] = Library.entries(ctx.alice, %{"kind" => "youtube"})
    {:ok, state} = Playback.start(ctx.alice, audio.id)

    Playback.save(ctx.alice, audio.id, state.session_id, %{
      "sequence" => 1,
      "position" => 10,
      "duration" => 100,
      "ended" => false
    })

    assert [%{id: id}] =
             Library.entries(ctx.alice, %{
               "status" => "in_progress",
               "kind" => "podcast",
               "source" => to_string(sub.feed_id)
             })

    assert id == audio.id
    assert Library.entries(ctx.bob, %{"kind" => "youtube"}) == []
    Playback.mark(ctx.alice, audio.id, :new)
    assert length(Library.entries(ctx.alice, %{"status" => "new"})) == 2
  end

  test "filters before applying the latest-100 limit and orders ties consistently", ctx do
    entries =
      for n <- 1..105,
          do: %{hd(ctx.preview.entries) | external_id: "episode-#{n}", title: "Episode #{n}"}

    Library.subscribe(ctx.alice, %{ctx.preview | entries: entries})
    newest = Library.entries(ctx.alice)
    assert length(newest) == 100
    assert Enum.map(newest, & &1.id) == Enum.sort(Enum.map(newest, & &1.id), :desc)
    oldest = Repo.one!(from e in Entry, order_by: [asc: e.id], limit: 1)
    Playback.mark(ctx.alice, oldest.id, :completed)
    assert [%{id: id}] = Library.entries(ctx.alice, %{"status" => "completed"})
    assert id == oldest.id
  end

  # New and all items run by publication. What is in progress runs by when it was last played,
  # what is finished by when it was finished, and loading more follows the same order.
  test "each list sorts by its own date, and loading more follows it", ctx do
    episodes =
      for {n, day} <- [{1, 3}, {2, 2}, {3, 1}],
          do: %{
            hd(ctx.preview.entries)
            | external_id: "e#{n}",
              title: "Episode #{n}",
              published_at: DateTime.add(~U[2026-09-01 12:00:00.000000Z], day, :day)
          }

    {:ok, _} = Library.subscribe(ctx.alice, %{ctx.preview | entries: episodes})
    ids = Map.new(Library.entries(ctx.alice), &{&1.title, &1.id})
    titles = fn entries -> Enum.map(entries, & &1.title) end

    # Episode 3 was published first, played last and finished first.
    for {title, minute} <- [{"Episode 3", 30}, {"Episode 1", 20}, {"Episode 2", 10}] do
      Playback.start(ctx.alice, ids[title])

      Repo.update_all(from(p in Sikio.Playback.State, where: p.entry_id == ^ids[title]),
        set: [status: :in_progress, session_id: nil, updated_at: at(minute)]
      )
    end

    assert titles.(Library.entries(ctx.alice)) == ["Episode 1", "Episode 2", "Episode 3"]
    played = Library.entries(ctx.alice, %{"status" => "in_progress"})
    assert titles.(played) == ["Episode 3", "Episode 1", "Episode 2"]

    assert titles.(Library.entries(ctx.alice, %{"status" => "in_progress"}, after: hd(played))) ==
             ["Episode 1", "Episode 2"]

    for {title, minute} <- [{"Episode 3", 5}, {"Episode 1", 50}, {"Episode 2", 40}] do
      Repo.update_all(from(p in Sikio.Playback.State, where: p.entry_id == ^ids[title]),
        set: [status: :completed, completed_at: at(minute)]
      )
    end

    finished = Library.entries(ctx.alice, %{"status" => "completed"})
    assert titles.(finished) == ["Episode 1", "Episode 2", "Episode 3"]

    assert titles.(
             Library.entries(ctx.alice, %{"status" => "completed"}, after: Enum.at(finished, 1))
           ) ==
             ["Episode 3"]
  end

  defp at(minute), do: DateTime.add(~U[2026-10-01 12:00:00.000000Z], minute, :minute)

  # A search looks where a reader remembers words from: the title, the notes and the excerpt. It
  # stays inside the account's own subscriptions and takes what was typed as text, not a pattern.
  test "search finds words in titles, notes and excerpts", ctx do
    entry = hd(ctx.preview.entries)

    entries = [
      %{entry | external_id: "a", title: "Bridges that sing", description: nil, excerpt: nil},
      %{
        entry
        | external_id: "b",
          title: "Bread",
          description: "<p>About <em>old</em> BRIDGES</p>",
          excerpt: nil
      },
      %{entry | external_id: "c", title: "Tea", description: nil, excerpt: "bridges at dawn"},
      %{entry | external_id: "d", title: "50% off", description: nil, excerpt: nil},
      %{entry | external_id: "e", title: "Ärger im Hafen", description: nil, excerpt: nil},
      %{entry | external_id: "f", title: "Ask me? [live]", description: nil, excerpt: nil}
    ]

    Library.subscribe(ctx.alice, %{ctx.preview | entries: entries})

    titles = fn filters ->
      ctx.alice |> Library.entries(filters) |> Enum.map(& &1.title) |> Enum.sort()
    end

    assert titles.(%{"q" => "bridges"}) == ["Bread", "Bridges that sing", "Tea"]
    assert titles.(%{"q" => "  sing "}) == ["Bridges that sing"]
    assert titles.(%{"q" => "%"}) == ["50% off"]
    assert titles.(%{"q" => "_"}) == []
    assert titles.(%{"q" => "?"}) == ["Ask me? [live]"]
    assert titles.(%{"q" => "[live]"}) == ["Ask me? [live]"]
    assert titles.(%{"q" => "*"}) == []
    # Words set apart by markup still read as one phrase.
    assert titles.(%{"q" => "about old bridges"}) == ["Bread"]
    # Case is ignored beyond ASCII as well.
    assert titles.(%{"q" => "ÄRGER"}) == ["Ärger im Hafen"]
    # The notes are HTML. Their markup is not what anybody remembers.
    assert titles.(%{"q" => "<p>"}) == []
    assert titles.(%{"q" => "p>"}) == []
    assert Library.count(ctx.alice, %{"q" => "bridges"}) == 3
    assert Library.entries(ctx.bob, %{"q" => "bridges"}) == []
  end

  # The search follows the notes as a poll changes them, and forgets a source that is removed.
  test "search follows changed notes and forgets removed items", ctx do
    entry = %{hd(ctx.preview.entries) | title: "Bread", description: "<p>About bridges</p>"}
    {:ok, _} = Library.subscribe(ctx.alice, %{ctx.preview | entries: [entry]})
    search = fn q -> ctx.alice |> Library.entries(%{"q" => q}) |> Enum.map(& &1.title) end
    assert search.("bridges") == ["Bread"]

    Sikio.Feeds.store(%{ctx.preview | entries: [%{entry | description: "<p>About tunnels</p>"}]})
    assert search.("tunnels") == ["Bread"]
    assert search.("bridges") == []

    Repo.delete_all(Entry)
    assert search.("tunnels") == []
  end

  # A poll that leaves the notes out keeps the stored ones, and the search keeps finding them,
  # even when the same poll changes something else about the item.
  test "search finds notes a later poll left out", ctx do
    entry = %{hd(ctx.preview.entries) | title: "Bread", description: "<p>About old bridges</p>"}
    Library.subscribe(ctx.alice, %{ctx.preview | entries: [entry]})

    Sikio.Feeds.store(%{
      ctx.preview
      | entries: [%{entry | title: "Bread rolls", description: nil, excerpt: nil}]
    })

    assert [%{title: "Bread rolls"}] = Library.entries(ctx.alice, %{"q" => "bridges"})
  end

  # A list grows as it is scrolled. Each batch continues after the last entry shown, by date and
  # then id, so an episode that arrives meanwhile neither repeats one nor skips one. Entries
  # without a date come last.
  test "entries continue after the last one shown", ctx do
    dated =
      for n <- 1..5,
          do: %{
            hd(ctx.preview.entries)
            | external_id: "episode-#{n}",
              title: "Episode #{n}",
              published_at: ~U[2026-09-01 00:00:00Z] |> DateTime.add(div(n, 2), :day)
          }

    undated = for n <- 6..7, do: %{hd(dated) | external_id: "episode-#{n}", published_at: nil}
    Library.subscribe(ctx.alice, %{ctx.preview | entries: dated ++ undated})

    all = Library.entries(ctx.alice, %{}, limit: 10)
    assert length(all) == 7

    pages =
      Stream.unfold(nil, fn
        :done ->
          nil

        last ->
          page = Library.entries(ctx.alice, %{}, limit: 2, after: last)

          if page == [],
            do: nil,
            else: {page, if(length(page) < 2, do: :done, else: List.last(page))}
      end)
      |> Enum.concat()

    assert Enum.map(pages, & &1.id) == Enum.map(all, & &1.id)
  end

  test "refresh deduplicates episodes, sends validators and preserves subscriptions", ctx do
    {:ok, sub} = Library.subscribe(ctx.alice, Map.put(ctx.preview, :etag, "v1"))

    Req.Test.stub(HTTP, fn conn ->
      assert Plug.Conn.get_req_header(conn, "if-none-match") == ["v1"]

      conn
      |> Plug.Conn.put_resp_header("etag", "v2")
      |> Plug.Conn.send_resp(200, podcast("Updated title"))
    end)

    assert {:ok, %{title: "Updated title", etag: "v2"}} = Feeds.refresh(sub.feed_id)
    assert Repo.aggregate(Entry, :count) == 1
    assert length(Library.subscriptions(ctx.alice)) == 1
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
    assert {:ok, %{last_error: nil}} = Feeds.refresh(sub.feed_id)
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "failed refresh keeps existing content and records the error", ctx do
    {:ok, sub} = Library.subscribe(ctx.alice, ctx.preview)
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, :unavailable} = Feeds.refresh(sub.feed_id)
    assert [%{feed: %{last_error: "unavailable"}}] = Library.subscriptions(ctx.alice)
    assert length(Library.entries(ctx.alice)) == 1
  end

  describe "media kinds" do
    setup :three_kinds

    # A reader asks for something to watch or something to hear, not for a platform.
    test "video covers YouTube and PeerTube, audio covers podcasts", ctx do
      kinds = fn filters -> ctx.alice |> Library.entries(filters) |> Enum.map(& &1.feed.kind) end

      assert Enum.sort(kinds.(%{"kind" => "video"})) == [:peertube, :youtube]
      assert kinds.(%{"kind" => "audio"}) == [:podcast]
    end

    # Links written before the two kinds existed keep narrowing to what they meant.
    test "the platform names of older links still narrow the list", ctx do
      assert Library.normalize_filters(%{"kind" => "youtube"})["kind"] == "video"
      assert Library.normalize_filters(%{"kind" => "podcast"})["kind"] == "audio"
      assert Library.normalize_filters(%{"kind" => "peertube"})["kind"] == ""
      assert length(Library.entries(ctx.alice, %{"kind" => "youtube"})) == 2
    end
  end

  describe "counts/1" do
    setup :three_kinds

    test "every view, kind and source is counted for this account alone", ctx do
      {:ok, _} = Library.subscribe(ctx.bob, ctx.preview)
      entries = ctx.entries
      {:ok, _} = Playback.mark(ctx.alice, entries.podcast.id, :completed)
      {:ok, %{session_id: session}} = Playback.start(ctx.alice, entries.youtube.id)

      {:ok, _} =
        Playback.save(ctx.alice, entries.youtube.id, session, %{
          "sequence" => 1,
          "position" => 30,
          "duration" => 100,
          "ended" => false
        })

      # Somebody else finishing the same episode changes nothing here.
      {:ok, _} = Playback.mark(ctx.bob, entries.podcast.id, :new)

      counts = ctx.alice |> Library.counts() |> Library.tally(%{})

      assert Map.take(counts, [:all, :new, :in_progress, :completed]) ==
               %{all: 3, new: 1, in_progress: 1, completed: 1}

      assert Map.take(counts, [:video, :audio]) == %{video: 2, audio: 1}

      assert counts.sources == %{
               entries.podcast.feed_id => 0,
               entries.youtube.feed_id => 0,
               entries.peertube.feed_id => 1
             }
    end

    # The number beside a link is how many items that link shows, so it honours the filters the
    # link keeps. A source without a status counts what is new.
    test "a count honours the other filters in force", ctx do
      entries = ctx.entries
      {:ok, _} = Playback.mark(ctx.alice, entries.podcast.id, :completed)
      rows = Library.counts(ctx.alice)

      videos = Library.tally(rows, %{"kind" => "video"})
      assert Map.take(videos, [:all, :new, :completed]) == %{all: 2, new: 2, completed: 0}

      finished = Library.tally(rows, %{"status" => "completed"})
      assert Map.take(finished, [:video, :audio]) == %{video: 0, audio: 1}
      assert finished.sources[entries.podcast.feed_id] == 1
      assert finished.sources[entries.youtube.feed_id] == 0
    end

    test "an account without sources counts nothing", ctx do
      assert ctx.bob |> Library.counts() |> Library.tally(%{}) ==
               %{
                 all: 0,
                 new: 0,
                 in_progress: 0,
                 completed: 0,
                 video: 0,
                 audio: 0,
                 sources: %{},
                 tags: %{}
               }
    end
  end

  # A podcast, a YouTube channel and a PeerTube instance, one entry each, for alice.
  defp three_kinds(ctx) do
    {:ok, _} = Library.subscribe(ctx.alice, ctx.preview)
    {:ok, youtube} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(ctx.alice, youtube)
    {:ok, peertube} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(ctx.alice, peertube)

    %{entries: Map.new(Library.entries(ctx.alice), &{&1.feed.kind, &1})}
  end
end
