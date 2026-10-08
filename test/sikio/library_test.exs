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
  alias Sikio.Library.Events
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

  # The mini player uses `listed?/3` to check whether the current list contains the playing entry.
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

  test "filters status and source independently and together within the account", ctx do
    {:ok, sub} = Library.subscribe(ctx.alice, ctx.preview)
    [audio] = Library.entries(ctx.alice)

    {:ok, video} =
      Parser.parse(
        youtube(),
        youtube_feed_url()
      )

    Library.subscribe(ctx.alice, video)
    Library.subscribe(ctx.bob, ctx.preview)
    Playback.mark(ctx.bob, audio.id, :heard)
    assert length(Library.entries(ctx.alice, %{"status" => "inbox"})) == 2
    assert Library.entries(ctx.alice, %{"status" => "heard"}) == []
    assert [item] = Library.entries(ctx.alice, %{"source" => to_string(sub.feed_id)})
    assert item.id == audio.id
    {:ok, state} = Playback.start(ctx.alice, audio.id)

    Playback.save(ctx.alice, audio.id, state.session_id, %{
      "sequence" => 1,
      "position" => 10,
      "duration" => 100,
      "ended" => false
    })

    # Playing an entry moves it from the inbox to the queue.
    assert [%{id: id}] =
             Library.entries(ctx.alice, %{"status" => "queue", "source" => to_string(sub.feed_id)})

    assert id == audio.id
    assert length(Library.entries(ctx.alice, %{"status" => "inbox"})) == 1
    Playback.mark(ctx.alice, audio.id, :new)
    assert length(Library.entries(ctx.alice, %{"status" => "inbox"})) == 2
    assert Library.entries(ctx.alice, %{"status" => "queue"}) == []
  end

  # Status values from before the inbox map to the current list names, so old URLs keep working.
  test "the old names of the lists still name them" do
    for {old, new} <- [{"new", "inbox"}, {"in_progress", "queue"}, {"completed", "heard"}] do
      assert Library.normalize_filters(%{"status" => old})["status"] == new
    end
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
    Playback.mark(ctx.alice, oldest.id, :heard)
    assert [%{id: id}] = Library.entries(ctx.alice, %{"status" => "heard"})
    assert id == oldest.id
  end

  # The default list sorts by publication date, the queue by rank and the history by
  # `completed_at`. Pagination with `after:` and `before:` follows the same order.
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

    # Episode 3 is the oldest, queued first and heard first.
    for title <- ["Episode 3", "Episode 1", "Episode 2"],
        do: {:ok, _} = Playback.enqueue(ctx.alice, ids[title], :last)

    assert titles.(Library.entries(ctx.alice)) == ["Episode 1", "Episode 2", "Episode 3"]
    queued = Library.entries(ctx.alice, %{"status" => "queue"})
    assert titles.(queued) == ["Episode 3", "Episode 1", "Episode 2"]

    assert titles.(Library.entries(ctx.alice, %{"status" => "queue"}, after: hd(queued))) ==
             ["Episode 1", "Episode 2"]

    assert titles.(Library.entries(ctx.alice, %{"status" => "queue"}, before: List.last(queued))) ==
             ["Episode 3", "Episode 1"]

    for {title, minute} <- [{"Episode 3", 5}, {"Episode 1", 50}, {"Episode 2", 40}] do
      Repo.update_all(from(p in Sikio.Playback.State, where: p.entry_id == ^ids[title]),
        set: [status: :heard, completed_at: at(minute)]
      )
    end

    heard = Library.entries(ctx.alice, %{"status" => "heard"})
    assert titles.(heard) == ["Episode 1", "Episode 2", "Episode 3"]

    assert titles.(Library.entries(ctx.alice, %{"status" => "heard"}, after: Enum.at(heard, 1))) ==
             ["Episode 3"]

    assert titles.(Library.entries(ctx.alice, %{"status" => "heard"}, before: Enum.at(heard, 1))) ==
             ["Episode 1"]
  end

  # Seven entries: pairs that share a date, and two without one.
  defp subscribe_with_ties(ctx) do
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
  end

  defp at(minute), do: DateTime.add(~U[2026-10-01 12:00:00.000000Z], minute, :minute)

  # Search matches title, notes and excerpt within the account's subscriptions. The query is
  # literal text, so `%`, `_` and `*` are not wildcards.
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
    # A phrase split by HTML tags still matches.
    assert titles.(%{"q" => "about old bridges"}) == ["Bread"]
    # Matching is case-insensitive beyond ASCII.
    assert titles.(%{"q" => "ÄRGER"}) == ["Ärger im Hafen"]
    # HTML markup in the notes is not searchable.
    assert titles.(%{"q" => "<p>"}) == []
    assert titles.(%{"q" => "p>"}) == []
    assert Library.count(ctx.alice, %{"q" => "bridges"}) == 3
    assert Library.entries(ctx.bob, %{"q" => "bridges"}) == []
  end

  # The search index follows changed notes and drops deleted entries.
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

  # A poll without notes keeps the stored notes searchable, even when it changes the title.
  test "search finds notes a later poll left out", ctx do
    entry = %{hd(ctx.preview.entries) | title: "Bread", description: "<p>About old bridges</p>"}
    Library.subscribe(ctx.alice, %{ctx.preview | entries: [entry]})

    Sikio.Feeds.store(%{
      ctx.preview
      | entries: [%{entry | title: "Bread rolls", description: nil, excerpt: nil}]
    })

    assert [%{title: "Bread rolls"}] = Library.entries(ctx.alice, %{"q" => "bridges"})
  end

  # Infinite scroll uses keyset pagination by date, then id. Offsets would repeat or skip entries
  # when new ones arrive. The pages must concatenate to the full list, including undated entries.
  test "entries continue after the last one shown", ctx do
    subscribe_with_ties(ctx)

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

  # A list opened in its middle grows upwards with `before:`. Those pages, read from the end,
  # also concatenate to the full list, including ties and undated entries.
  test "entries continue before the first one shown", ctx do
    subscribe_with_ties(ctx)

    all = Library.entries(ctx.alice, %{}, limit: 10)

    pages =
      Stream.unfold(List.last(all), fn
        :done ->
          nil

        first ->
          page = Library.entries(ctx.alice, %{}, limit: 2, before: first)

          if page == [],
            do: nil,
            else: {page, if(length(page) < 2, do: :done, else: hd(page))}
      end)
      |> Enum.reverse()
      |> Enum.concat()

    assert Enum.map(pages ++ [List.last(all)], & &1.id) == Enum.map(all, & &1.id)
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

  # `delivery` sends new entries to the inbox, the queue tail or the archive.
  # Entries present at subscription time stay in the inbox.
  test "new episodes go where each subscription sends them", ctx do
    carol = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, alices} = Library.subscribe(ctx.alice, ctx.preview)
    {:ok, bobs} = Library.subscribe(ctx.bob, ctx.preview)
    {:ok, _carols} = Library.subscribe(carol, ctx.preview)
    {:ok, _} = Library.configure(ctx.alice, alices.id, %{delivery: :queue}, [])
    {:ok, _} = Library.configure(ctx.bob, bobs.id, %{delivery: :skip}, [])

    assert {:error, :not_found} =
             Library.configure(ctx.bob, alices.id, %{delivery: :skip}, [])

    [first] = Library.entries(ctx.alice)

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast_later()) end)
    assert {:ok, _} = Feeds.refresh(alices.feed_id, &Library.deliver/2)
    [%{id: second}] = Library.entries(ctx.alice, %{"q" => "Later"})

    assert Sikio.Playback.queue(ctx.alice) == [second]

    assert [%{id: ^second}] =
             Library.entries(ctx.bob, %{"status" => ""})
             |> Enum.filter(&(&1.playback && &1.playback.status == :archived))

    assert Enum.map(Library.entries(carol, %{"status" => "inbox"}), & &1.id) |> Enum.sort() ==
             Enum.sort([first.id, second])

    assert Enum.map(Library.entries(ctx.alice, %{"status" => "inbox"}), & &1.id) == [first.id]
    assert Library.entries(ctx.bob, %{"status" => "inbox"}) |> Enum.map(& &1.id) == [first.id]
  end

  # Feeds are shared, so a custom name belongs to the subscription. Entries show it for that
  # account only. A blank name restores the feed title.
  test "a subscription takes a name of its own, which its entries carry", ctx do
    {:ok, alices} = Library.subscribe(ctx.alice, ctx.preview)
    {:ok, _} = Library.subscribe(ctx.bob, ctx.preview)

    assert {:ok, %{name: "Late Night"}} =
             Library.configure(ctx.alice, alices.id, %{name: " Late Night "}, [])

    assert [%{source_name: "Late Night"}] = Library.entries(ctx.alice)
    assert [%{source_name: "Small Hours"}] = Library.entries(ctx.bob)

    assert %{source_name: "Late Night"} =
             Library.entry(ctx.alice, hd(Library.entries(ctx.alice)).id)

    assert {:ok, %{name: nil}} = Library.configure(ctx.alice, alices.id, %{name: "  "}, [])
    assert [%{source_name: "Small Hours"}] = Library.entries(ctx.alice)
  end

  test "failed refresh keeps existing content and records the error", ctx do
    {:ok, sub} = Library.subscribe(ctx.alice, ctx.preview)
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, :unavailable} = Feeds.refresh(sub.feed_id)
    assert [%{feed: %{last_error: "unavailable"}}] = Library.subscriptions(ctx.alice)
    assert length(Library.entries(ctx.alice)) == 1
  end

  # `short` is set per entry, visibility per subscription. A hidden Short leaves lists, counts and
  # the queue. `visible_entry_id/2` and progress saves still work for it.
  test "a subscription leaves a channel's Shorts out until it asks for them", ctx do
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(ctx.alice, preview)
    {:ok, subscription} = Library.subscribe(ctx.bob, preview)
    [entry] = Library.entries(ctx.alice)
    {:ok, _} = Playback.enqueue(ctx.alice, entry.id, :last)
    {:ok, %{session_id: session}} = Playback.start(ctx.alice, entry.id)
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [short: true])

    assert Library.entries(ctx.alice) == []
    assert Library.counts(ctx.alice) == []
    assert Playback.queue(ctx.alice) == []
    assert Library.visible_entry_id(ctx.alice, entry.id) == entry.id

    assert {:ok, _} =
             Playback.save(ctx.alice, entry.id, session, %{
               "sequence" => 1,
               "position" => 30,
               "duration" => 100,
               "ended" => false
             })

    assert {:ok, %{shorts: true}} =
             Library.configure(ctx.bob, subscription.id, %{"shorts" => "true"}, [])

    assert [%{id: id}] = Library.entries(ctx.bob)
    assert id == entry.id
    assert Library.entries(ctx.alice) == []
  end

  # A hidden Short is not delivered. Enabling Shorts later does not add it to the queue.
  test "a hidden Short is not delivered to the queue", ctx do
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, subscription} = Library.subscribe(ctx.alice, preview)
    {:ok, _} = Library.configure(ctx.alice, subscription.id, %{"delivery" => "queue"}, [])
    [entry] = preview.entries
    short = %{entry | external_id: "yt:video:zzzzzzzzzzz", video_id: "zzzzzzzzzzz"}

    {:ok, _} =
      Feeds.store(
        %{preview | entries: [Map.put(short, :short, true) | preview.entries]},
        &Library.deliver/2
      )

    {:ok, _} = Library.configure(ctx.alice, subscription.id, %{"shorts" => "true"}, [])
    assert Playback.queue(ctx.alice) == []
  end

  # Each broadcast reloads every open view, so an unchanged save broadcasts nothing.
  test "a subscription's settings tell the account's views only when they change", ctx do
    {:ok, subscription} = Library.subscribe(ctx.alice, ctx.preview)
    Events.subscribe(ctx.alice)

    {:ok, _} = Library.configure(ctx.alice, subscription.id, %{"delivery" => "inbox"}, [])
    refute_received {:subscription_changed, _}

    {:ok, _} = Library.configure(ctx.alice, subscription.id, %{"delivery" => "queue"}, [])
    assert_received {:subscription_changed, id}
    assert id == subscription.id
  end

  # The settings dialog saves settings and tags together. Invalid settings change neither.
  test "configure saves settings and tags at once, or neither", ctx do
    {:ok, subscription} = Library.subscribe(ctx.alice, ctx.preview)
    {:ok, _} = Sikio.Tags.set(ctx.alice, subscription.id, ["Old"])
    Events.subscribe(ctx.alice)

    long = String.duplicate("x", 201)

    assert {:error, %Ecto.Changeset{errors: [name: _]}} =
             Library.configure(ctx.alice, subscription.id, %{name: long}, ["New"])

    assert Enum.map(Sikio.Tags.of(ctx.alice, subscription.id), & &1.name) == ["Old"]
    assert [%{name: nil}] = Library.subscriptions(ctx.alice)
    refute_received {:subscription_changed, _}
    refute_received {:tags_changed, _}

    assert {:ok, %{name: "Late Night"}} =
             Library.configure(ctx.alice, subscription.id, %{name: "Late Night"}, ["New"])

    assert Enum.map(Sikio.Tags.of(ctx.alice, subscription.id), & &1.name) == ["New"]
    assert_received {:subscription_changed, _}
    assert_received {:tags_changed, _}

    # Unchanged tags send no broadcast, since every open view reloads on it.
    {:ok, _} = Library.configure(ctx.alice, subscription.id, %{name: "Later"}, ["New"])
    assert_received {:subscription_changed, _}
    refute_received {:tags_changed, _}

    assert {:error, :not_found} =
             Library.configure(ctx.bob, subscription.id, %{name: "Mine"}, ["Theirs"])
  end

  describe "counts/1" do
    setup :three_kinds

    test "every view and source is counted for this account alone", ctx do
      {:ok, _} = Library.subscribe(ctx.bob, ctx.preview)
      entries = ctx.entries
      {:ok, _} = Playback.mark(ctx.alice, entries.podcast.id, :heard)
      {:ok, %{session_id: session}} = Playback.start(ctx.alice, entries.youtube.id)

      {:ok, _} =
        Playback.save(ctx.alice, entries.youtube.id, session, %{
          "sequence" => 1,
          "position" => 30,
          "duration" => 100,
          "ended" => false
        })

      # Another account's playback state does not affect these counts.
      {:ok, _} = Playback.mark(ctx.bob, entries.podcast.id, :new)

      counts = ctx.alice |> Library.counts() |> Library.tally(%{})

      # Playing the video queued it.
      assert Map.take(counts, [:all, :inbox, :queue, :heard]) ==
               %{all: 3, inbox: 1, queue: 1, heard: 1}

      assert counts.sources == %{
               entries.podcast.feed_id => 0,
               entries.youtube.feed_id => 0,
               entries.peertube.feed_id => 1
             }
    end

    # A count equals the entries its link would show, so it applies the active filters.
    test "a count honours the other filters in force", ctx do
      entries = ctx.entries
      {:ok, _} = Playback.mark(ctx.alice, entries.podcast.id, :heard)
      rows = Library.counts(ctx.alice)

      heard = Library.tally(rows, %{"status" => "heard"})
      assert Map.take(heard, [:all, :inbox, :heard]) == %{all: 3, inbox: 2, heard: 1}
      assert heard.sources[entries.podcast.feed_id] == 1
      assert heard.sources[entries.youtube.feed_id] == 0
    end

    # A heard entry queued again stays heard. It counts in the history and the queue, and once in
    # all items.
    test "a heard item queued again counts in the history and the queue", ctx do
      entries = ctx.entries
      {:ok, _} = Playback.mark(ctx.alice, entries.podcast.id, :heard)
      {:ok, _} = Playback.enqueue(ctx.alice, entries.podcast.id, :last)

      counts = ctx.alice |> Library.counts() |> Library.tally(%{})
      assert Map.take(counts, [:all, :queue, :heard]) == %{all: 3, queue: 1, heard: 1}

      history = Library.entries(ctx.alice, %{"status" => "heard"})
      assert Enum.map(history, & &1.id) == [entries.podcast.id]
      assert length(history) == counts.heard
    end

    test "an account without sources counts nothing", ctx do
      assert ctx.bob |> Library.counts() |> Library.tally(%{}) ==
               %{
                 all: 0,
                 inbox: 0,
                 queue: 0,
                 heard: 0,
                 sources: %{},
                 tags: %{}
               }
    end
  end

  # Subscribes alice to a podcast, a YouTube channel and a PeerTube feed, one entry each.
  defp three_kinds(ctx) do
    {:ok, _} = Library.subscribe(ctx.alice, ctx.preview)
    {:ok, youtube} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(ctx.alice, youtube)
    {:ok, peertube} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(ctx.alice, peertube)

    %{entries: Map.new(Library.entries(ctx.alice), &{&1.feed.kind, &1})}
  end
end
