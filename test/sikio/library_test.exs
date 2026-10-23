# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.LibraryTest do
  @moduledoc false
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Discovery
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

  # Every open page keeps its rows and sidebar. They carry what the pages show, not the notes,
  # the search text or the feed's fetch bookkeeping. The detail reads the whole entry.
  test "lists and sources leave out what no list shows", ctx do
    {:ok, _} = Library.subscribe(ctx.alice, ctx.preview)
    [listed] = Library.entries(ctx.alice)
    full = Library.entry(ctx.alice, listed.id)
    assert full.description && full.search_text && full.feed.inserted_at

    assert %{description: nil, search_text: nil, inserted_at: nil} = listed
    assert listed.title == full.title and listed.excerpt == full.excerpt
    assert listed.playback == full.playback and listed.source_name == full.source_name
    assert %{inserted_at: nil, updated_at: nil, etag: nil} = listed.feed

    assert Map.take(listed.feed, [:id, :kind, :title, :url, :page_url, :icon_url]) ==
             Map.take(full.feed, [:id, :kind, :title, :url, :page_url, :icon_url])

    [source] = Library.subscriptions(ctx.alice)
    assert %{inserted_at: nil, updated_at: nil} = source.feed
    assert source.feed.title == full.feed.title and source.feed.url == full.feed.url
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

  # Within a source or tag the first list holds unfinished items; elsewhere it is the inbox.
  test "the inbox of a source or tag is its list of unfinished items" do
    assert Library.normalize_filters(%{"source" => "1", "status" => "inbox"})["status"] == "open"
    assert Library.normalize_filters(%{"tag" => "1", "status" => "new"})["status"] == "open"
    assert Library.normalize_filters(%{"status" => "open"})["status"] == "inbox"
    assert Library.normalize_filters(%{"source" => "1", "status" => "heard"})["status"] == "heard"
  end

  # Status values from before the inbox map to the current list names, so old URLs keep working.
  test "the old names of the lists still name them" do
    for {old, new} <- [{"new", "inbox"}, {"in_progress", "queue"}, {"completed", "heard"}] do
      assert Library.normalize_filters(%{"status" => old})["status"] == new
    end
  end

  # A day is a calendar date in the reader's time zone, given as minutes ahead of UTC.
  test "keeps a valid day and offset only for the history" do
    filters = Library.normalize_filters(%{"status" => "heard", "day" => "2026-10-07"})
    assert {filters["day"], filters["offset"]} == {"2026-10-07", 0}

    assert Library.normalize_filters(%{"status" => "inbox", "day" => "2026-10-07"})["day"] == ""
    assert Library.normalize_filters(%{"status" => "heard", "day" => "2026-02-30"})["day"] == ""
    assert Library.normalize_filters(%{"status" => "heard", "day" => "9999-12-31"})["day"] == ""
    assert Library.normalize_filters(%{"offset" => 120})["offset"] == 120
    assert Library.normalize_filters(%{"offset" => -780})["offset"] == -780
    assert Library.normalize_filters(%{"offset" => 5000})["offset"] == 0
    assert Library.normalize_filters(%{"offset" => "120"})["offset"] == 0
  end

  # 23:30 UTC on 6 October is 01:30 on 7 October two hours east of UTC.
  test "the history of a day holds the entries heard on that local day", ctx do
    episodes =
      for n <- 1..4,
          do: %{hd(ctx.preview.entries) | external_id: "e#{n}", title: "Episode #{n}"}

    {:ok, subscription} = Library.subscribe(ctx.alice, %{ctx.preview | entries: episodes})
    ids = Map.new(Library.entries(ctx.alice), &{&1.title, &1.id})

    for {title, at} <- [
          {"Episode 1", ~U[2026-10-06 21:59:00.000000Z]},
          {"Episode 2", ~U[2026-10-06 23:30:00.000000Z]},
          {"Episode 3", ~U[2026-10-07 21:59:00.000000Z]},
          {"Episode 4", ~U[2026-10-07 22:00:00.000000Z]}
        ] do
      Playback.mark(ctx.alice, ids[title], :heard)

      Repo.update_all(from(p in Sikio.Playback.State, where: p.entry_id == ^ids[title]),
        set: [completed_at: at]
      )
    end

    day = %{"status" => "heard", "day" => "2026-10-07", "offset" => 120}
    titles = Enum.map(Library.entries(ctx.alice, day), & &1.title)
    assert titles == ["Episode 3", "Episode 2"]
    assert Library.count(ctx.alice, day) == 2
    assert Library.entries(ctx.bob, day) == []

    elsewhere = Map.put(day, "source", to_string(subscription.feed_id + 1))
    assert Library.entries(ctx.alice, elsewhere) == []

    assert Library.heard_days(ctx.alice, day, ~D[2026-10-01]) ==
             %{~D[2026-10-06] => 1, ~D[2026-10-07] => 2, ~D[2026-10-08] => 1}

    assert Library.heard_days(ctx.alice, day, ~D[2026-09-01]) == %{}
    assert Library.heard_days(ctx.bob, day, ~D[2026-10-01]) == %{}
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

  # A new subscription brings its newest entry into the inbox. The older ones wait in the source,
  # archived for this account only. A later poll delivers new entries as before.
  test "subscribing puts only the newest entry into the inbox", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())
    {:ok, subscription} = Library.subscribe(ctx.alice, preview)
    source = to_string(subscription.feed_id)

    assert [%{title: newest}] = Library.entries(ctx.alice, %{"status" => "inbox"})
    assert newest == Enum.max_by(preview.entries, & &1.published_at, DateTime).title

    assert [%{playback: %{status: :archived}}] =
             Library.entries(ctx.alice, %{"source" => source, "status" => ""})
             |> Enum.reject(&(&1.title == newest))

    # Another account's view of the shared feed is its own.
    {:ok, _} = Library.subscribe(ctx.bob, preview)
    assert [%{title: ^newest}] = Library.entries(ctx.bob, %{"status" => "inbox"})

    # Subscribing again changes nothing the account did meanwhile.
    [older] =
      Library.entries(ctx.alice, %{"q" => "", "source" => source, "status" => ""})
      |> Enum.reject(&(&1.title == newest))

    Playback.mark(ctx.alice, older.id, :new)
    {:ok, _} = Library.subscribe(ctx.alice, preview)
    assert length(Library.entries(ctx.alice, %{"status" => "inbox"})) == 2
  end

  # A serial is followed from its start. Its present entries join the queue oldest first, and
  # entries of one date by title. The subscription keeps the delivery for later entries.
  test "subscribing can queue every present entry, oldest first", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())
    later = Enum.find(preview.entries, &(&1.title == "Later"))
    tie = %{later | external_id: "episode-tie", title: "A tie"}
    # Titles compare by their bytes on both databases, so lowercase sorts after uppercase.
    lower = %{later | external_id: "episode-lower", title: "a later"}
    preview = %{preview | entries: [later, lower, tie | preview.entries -- [later]]}

    {:ok, subscription} = Library.subscribe(ctx.alice, preview, existing: :all, delivery: :queue)
    assert subscription.delivery == :queue

    titles = Enum.map(Playback.queue(ctx.alice), &Library.entry(ctx.alice, &1).title)
    assert titles == ["One & two", "A tie", "Later", "a later"]
  end

  test "subscribing can bring every present entry to the inbox, or none", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())

    {:ok, _} = Library.subscribe(ctx.alice, preview, existing: :all, delivery: :inbox)
    assert length(Library.entries(ctx.alice, %{"status" => "inbox"})) == 2

    {:ok, bobs} = Library.subscribe(ctx.bob, preview, existing: :none, delivery: :inbox)
    assert Library.entries(ctx.bob, %{"status" => "inbox"}) == []

    assert [:archived, :archived] =
             Library.entries(ctx.bob, %{"source" => to_string(bobs.feed_id), "status" => ""})
             |> Enum.map(& &1.playback.status)
  end

  # The newest entry goes where later ones go. The archive takes every present entry.
  test "subscribing places the newest entry by the subscription's delivery", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())

    {:ok, _} = Library.subscribe(ctx.alice, preview, existing: :newest, delivery: :queue)
    assert [id] = Playback.queue(ctx.alice)
    assert Library.entry(ctx.alice, id).title == "Later"

    {:ok, bobs} = Library.subscribe(ctx.bob, preview, existing: :all, delivery: :skip)
    assert bobs.delivery == :skip
    assert Library.entries(ctx.bob, %{"status" => "inbox"}) == []
    assert Playback.queue(ctx.bob) == []
  end

  # An item the account saved to its inbox stays there when it later follows the source.
  test "subscribing leaves an item saved to the inbox in the inbox", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())
    oldest = Enum.min_by(preview.entries, & &1.published_at, DateTime)
    {:ok, saved} = Library.save(ctx.alice, preview, oldest.external_id, :inbox)

    {:ok, _} = Library.subscribe(ctx.alice, preview)
    assert saved.id in Enum.map(Library.entries(ctx.alice, %{"status" => "inbox"}), & &1.id)
  end

  # Entries of one date leave the one stored last as the newest, whatever their titles.
  test "subscribing takes the entry stored last among the newest of one date", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())
    later = Enum.find(preview.entries, &(&1.title == "Later"))
    other = %{later | external_id: "episode-tie", title: "Zusammenfassung"}
    preview = %{preview | entries: [other | preview.entries]}

    {:ok, subscription} = Library.subscribe(ctx.alice, preview)
    [%{id: newest}] = Library.entries(ctx.alice, %{"status" => "inbox"})

    ids = Repo.all(from e in Entry, where: e.feed_id == ^subscription.feed_id, select: e.id)
    assert newest == Enum.max(ids)
  end

  # A new subscription decides afresh about entries that an earlier one archived unplayed.
  # What the account heard or started stays.
  test "subscribing again places entries an earlier subscription archived", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())
    {:ok, first} = Library.subscribe(ctx.alice, preview)
    source = %{"source" => to_string(first.feed_id), "status" => ""}
    [later, older] = Library.entries(ctx.alice, source)
    assert older.playback.status == :archived

    {:ok, _} = Playback.mark(ctx.alice, later.id, :heard)
    {:ok, _} = Library.unsubscribe(ctx.alice, first.id)
    {:ok, _} = Library.subscribe(ctx.alice, preview, existing: :all, delivery: :inbox)

    assert [%{id: id}] = Library.entries(ctx.alice, %{"status" => "inbox"})
    assert id == older.id
    assert Library.entry(ctx.alice, later.id).playback.status == :heard
  end

  # A saved newest entry still counts as the newest, so no older entry joins it.
  test "subscribing after saving the newest entry brings no other", ctx do
    {:ok, preview} = Parser.parse(podcast_later(), feed_url())
    newest = Enum.max_by(preview.entries, & &1.published_at, DateTime)
    {:ok, saved} = Library.save(ctx.alice, preview, newest.external_id, :inbox)

    {:ok, _} = Library.subscribe(ctx.alice, preview)
    assert [%{id: id}] = Library.entries(ctx.alice, %{"status" => "inbox"})
    assert id == saved.id
  end

  # A website's feed link and Apple's directory may give two URLs of one feed. A new feed is
  # fetched at the URL in its `atom:link rel="self"`, so both URLs reach one feed and one entry.
  describe "a feed with a self URL" do
    setup do
      canonical = feed_url("feed/mp3/")
      %{canonical: canonical, alias_url: String.replace(canonical, "/feed/", "/index.php/feed/")}
    end

    # Serves `feeds` by host and path. The request goes to the pinned address, so the `host`
    # header carries the host.
    defp serve(feeds) do
      Req.Test.stub(HTTP, fn conn ->
        [host] = Plug.Conn.get_req_header(conn, "host")

        case Map.fetch(feeds, "https://" <> host <> conn.request_path) do
          {:ok, {:redirect, to}} ->
            conn |> Plug.Conn.put_resp_header("location", to) |> Plug.Conn.send_resp(301, "")

          {:ok, body} ->
            Plug.Conn.send_resp(conn, 200, body)

          :error ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)
    end

    defp assert_fetched_at_alias(%{alias_url: alias_url}),
      do: assert({:ok, %{url: ^alias_url}} = Discovery.fetch(alias_url))

    test "subscribing at another URL of a saved entry's feed adds no second entry", ctx do
      named = podcast_naming(ctx.canonical)
      serve(%{ctx.canonical => named, ctx.alias_url => named})

      {:ok, linked} = Discovery.fetch(ctx.canonical)
      {:ok, saved} = Library.save(ctx.alice, linked, "episode-1", :queue)

      {:ok, [listed]} = Discovery.discover(ctx.alias_url)
      {:ok, subscription} = Library.subscribe(ctx.alice, listed, existing: :all)

      assert subscription.feed_id == saved.feed_id
      assert [%{id: id}] = Library.entries(ctx.alice, %{"status" => ""})
      assert id == saved.id
      assert Library.entries(ctx.alice, %{"status" => "inbox"}) == []
    end

    # A feed on a shared host may give another publisher's feed as its self URL. Fetching it
    # gives that feed's own content, so nothing reaches the other feed's subscribers.
    test "gives the content served at the self URL, never the content that names it", ctx do
      serve(%{
        ctx.canonical => podcast_naming(ctx.canonical),
        ctx.alias_url =>
          ctx.canonical |> podcast_naming() |> String.replace("One &amp; two", "Planted")
      })

      {:ok, victim} = Discovery.fetch(ctx.canonical)
      {:ok, _} = Library.subscribe(ctx.bob, victim)

      {:ok, fetched} = Discovery.fetch(ctx.alias_url)
      assert fetched.url == ctx.canonical
      {:ok, _} = Library.subscribe(ctx.alice, fetched)

      assert [%{title: "One & two"}] = Library.entries(ctx.bob, %{"status" => ""})
    end

    test "keeps the fetched URL when the self URL serves no feed", ctx do
      serve(%{ctx.alias_url => podcast_naming(ctx.canonical)})
      assert_fetched_at_alias(ctx)
    end

    # A feed stored at its other URL keeps its row and its subscribers.
    test "a stored feed keeps its URL", ctx do
      named = podcast_naming(ctx.canonical)
      serve(%{ctx.canonical => named, ctx.alias_url => named})
      {:ok, stored} = Parser.parse(named, ctx.alias_url)
      {:ok, _} = Library.subscribe(ctx.alice, stored)

      assert_fetched_at_alias(ctx)
    end

    # A feed at the self URL with other entries is another feed, such as a variant of the show.
    test "keeps the fetched URL when the feed at the self URL holds other entries", ctx do
      serve(%{
        ctx.alias_url => podcast_naming(ctx.canonical),
        ctx.canonical => podcast_naming(ctx.canonical, podcast_later())
      })

      assert_fetched_at_alias(ctx)
    end

    # A redirect would key the feed to a URL the self URL does not give.
    test "keeps the fetched URL when the self URL redirects", ctx do
      for elsewhere <- [feed_url("feed"), String.replace(ctx.canonical, "/mp3/", "/aac/")] do
        serve(%{
          ctx.alias_url => podcast_naming(ctx.canonical),
          ctx.canonical => {:redirect, elsewhere},
          elsewhere => podcast_naming(ctx.canonical)
        })

        assert_fetched_at_alias(ctx)
      end
    end

    # A stored feed whose URL now redirects is still the stored feed.
    test "keeps a stored feed whose URL redirects", ctx do
      moved = String.replace(ctx.alias_url, "/index.php/", "/moved/")
      named = podcast_naming(ctx.canonical)
      serve(%{ctx.alias_url => {:redirect, moved}, moved => named, ctx.canonical => named})
      {:ok, stored} = Parser.parse(named, ctx.alias_url)
      {:ok, _} = Library.subscribe(ctx.alice, stored)

      assert {:ok, %{url: url}} = Discovery.fetch(ctx.alias_url)
      assert url == moved
    end

    # Two feeds that give each other as self URL stay apart.
    test "keeps the fetched URL when the feed at the self URL gives another self URL", ctx do
      serve(%{
        ctx.alias_url => podcast_naming(ctx.canonical),
        ctx.canonical => podcast_naming(ctx.alias_url)
      })

      assert_fetched_at_alias(ctx)
    end
  end

  # A channel's latest upload may be a Short, which the subscription hides by default. The newest
  # entry it shows goes to the inbox instead.
  test "subscribing brings the newest visible entry, not a hidden Short", ctx do
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    [video] = preview.entries

    older = %{
      Map.put(video, :short, false)
      | external_id: "yt:video:olderolder1",
        video_id: "olderolder1",
        title: "An older video",
        published_at: DateTime.add(video.published_at, -1, :day)
    }

    short = video |> Map.put(:short, true) |> Map.put(:title, "A Short")

    {:ok, _} = Library.subscribe(ctx.alice, %{preview | entries: [short, older]})
    assert [%{title: "An older video"}] = Library.entries(ctx.alice, %{"status" => "inbox"})
  end

  # `delivery` sends new entries to the inbox, the queue tail or the archive.
  # Of the entries present at subscription time, the newest stays in the inbox.
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

  describe "single entries" do
    # Bob follows the show. Alice follows nothing and saves one episode from her own link.
    setup ctx do
      {:ok, _} = Library.subscribe(ctx.bob, ctx.preview)
      carol = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
      %{external_id: hd(ctx.preview.entries).external_id, carol: carol}
    end

    defp save(ctx, at \\ :inbox), do: Library.save(ctx.alice, ctx.preview, ctx.external_id, at)

    test "a saved entry joins the account's library without a subscription", ctx do
      assert Library.entries(ctx.alice) == []
      Events.subscribe(ctx.alice)

      assert {:ok, entry} = save(ctx)
      assert {:ok, ^entry} = save(ctx)
      assert_received {:entry_saved, _}

      assert [%{id: id, source_name: "Small Hours"}] =
               Library.entries(ctx.alice, %{"status" => "inbox"})

      assert id == entry.id
      assert Library.entries(ctx.carol) == []
      assert (ctx.alice |> Library.counts() |> Library.tally(%{})).inbox == 1
    end

    # A film from the Mediathek search has no feed to follow. It is saved on its own.
    test "a Mediathek programme is saved to the queue", ctx do
      programme = mediathek_programme()

      %{preview: preview, external_id: id} =
        Discovery.mediathek_item(programme)

      assert {:ok, entry} = Library.save(ctx.alice, preview, id, :queue)
      assert Playback.queue(ctx.alice) == [entry.id]

      assert %{title: "Die Erfindung des Rades", feed: %{kind: :mediathek}} =
               Library.entry(ctx.alice, entry.id)
    end

    test "a saved entry can go to the end of the queue", ctx do
      {:ok, entry} = save(ctx, :queue)
      assert Playback.queue(ctx.alice) == [entry.id]
    end

    # Only the account's own link saves an entry. An episode the link does not hold is refused.
    test "an episode the preview does not hold is not saved", ctx do
      assert {:error, :not_found} = Library.save(ctx.alice, ctx.preview, "elsewhere", :inbox)
      assert Library.entries(ctx.alice) == []
    end

    # Removing takes the entry out of the library. Its playback state stays for a later save.
    test "a removed entry leaves the library and keeps its playback state", ctx do
      {:ok, entry} = save(ctx)
      {:ok, _} = Playback.mark(ctx.alice, entry.id, :heard)
      assert [_] = Library.entries(ctx.alice, %{"status" => "heard"})

      assert {:ok, _} = Library.remove_entry(ctx.alice, entry.id)
      assert Library.entries(ctx.alice) == []
      assert {:error, :not_found} = Library.remove_entry(ctx.alice, entry.id)
      assert {:error, :not_found} = Library.remove_entry(ctx.carol, entry.id)

      {:ok, _} = save(ctx)
      assert [%{playback: %{status: :heard}}] = Library.entries(ctx.alice)
    end

    # A video built from oEmbed has no notes and no length. It saves like any other entry.
    test "an older video built from oEmbed is saved", ctx do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/oembed" ->
            Req.Test.json(conn, %{
              title: "An old video",
              author_url: "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv"
            })

          "/feeds/videos.xml" ->
            Plug.Conn.send_resp(conn, 200, youtube())

          _page ->
            Plug.Conn.send_resp(conn, 200, "<html></html>")
        end
      end)

      {:ok, %{preview: preview, external_id: id}} =
        Discovery.item("https://youtu.be/zzzzzzzzzzz")

      assert {:ok, %{title: "An old video", published_at: nil}} =
               Library.save(ctx.alice, preview, id, :inbox)
    end

    # A Short saved singly shows even where the account follows the channel with Shorts off.
    test "a saved Short shows despite a subscription that hides Shorts", ctx do
      {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
      {:ok, _} = Library.subscribe(ctx.alice, video)
      [entry] = Library.entries(ctx.alice)
      Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [short: true])
      assert Library.entries(ctx.alice) == []

      {:ok, _} = Library.save(ctx.alice, video, entry.external_id, :queue)
      assert [_] = Library.entries(ctx.alice)
      assert Playback.queue(ctx.alice) == [entry.id]
    end

    # The entry stays after its channel is unfollowed, and its feed is not polled for it.
    test "a saved entry outlasts an unsubscribe and polls nothing", ctx do
      {:ok, sub} = Library.subscribe(ctx.alice, ctx.preview)
      {:ok, entry} = save(ctx)
      {:ok, _} = Library.unsubscribe(ctx.alice, sub.id)
      assert [_] = Library.entries(ctx.alice)

      {:ok, _} = Library.unsubscribe(ctx.bob, hd(Library.subscriptions(ctx.bob)).id)
      refute Library.active_feed?(entry.feed_id)
      refute entry.feed_id in Library.due_feed_ids()
    end
  end

  describe "favourites" do
    setup ctx do
      {:ok, subscription} = Library.subscribe(ctx.alice, ctx.preview)
      {:ok, _} = Library.subscribe(ctx.bob, ctx.preview)
      [entry] = Library.entries(ctx.alice)
      %{entry: entry, subscription: subscription}
    end

    test "a star belongs to the account and forms its own list", ctx do
      Events.subscribe(ctx.alice)
      id = ctx.entry.id

      assert {:ok, ^id} = Library.favourite(ctx.alice, id, true)
      assert {:ok, ^id} = Library.favourite(ctx.alice, id, true)
      assert_received {:favourite_changed, ^id}

      assert [%{id: ^id, favourite: true}] =
               Library.entries(ctx.alice, %{"status" => "favourites"})

      assert [%{favourite: false}] = Library.entries(ctx.bob)
      assert Library.entries(ctx.bob, %{"status" => "favourites"}) == []
      assert (ctx.alice |> Library.counts() |> Library.tally(%{})).favourites == 1
      assert Library.listed?(ctx.alice, %{"status" => "favourites"}, id)

      assert {:ok, ^id} = Library.favourite(ctx.alice, id, false)
      assert Library.entries(ctx.alice, %{"status" => "favourites"}) == []
      assert [%{favourite: false}] = Library.entries(ctx.alice)
    end

    test "an entry the account cannot see takes no star", ctx do
      carol = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
      assert {:error, :not_found} = Library.favourite(carol, ctx.entry.id, true)
      assert {:error, :not_found} = Library.favourite(ctx.alice, "nonsense", true)
      assert Library.entries(carol) == []
    end

    test "a favourite outlasts an unsubscribe", ctx do
      {:ok, _} = Library.favourite(ctx.alice, ctx.entry.id, true)
      {:ok, _} = Library.unsubscribe(ctx.alice, ctx.subscription.id)

      assert [%{followed: false, favourite: true}] =
               Library.entries(ctx.alice, %{"status" => "favourites"})
    end

    test "marking heard or archiving a list keeps the star", ctx do
      {:ok, _} = Library.favourite(ctx.alice, ctx.entry.id, true)
      {:ok, _} = Playback.mark(ctx.alice, ctx.entry.id, :heard)
      {:ok, _} = Playback.mark(ctx.alice, ctx.entry.id, :new)
      assert {:ok, 1} = Playback.mark_all(ctx.alice, %{"status" => "inbox"})

      assert [%{favourite: true, playback: %{status: :archived}}] =
               Library.entries(ctx.alice, %{"status" => "favourites"})
    end

    # A Short shows where it was chosen, as a saved one does.
    test "a starred Short shows despite a subscription that hides Shorts", ctx do
      {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
      {:ok, _} = Library.subscribe(ctx.alice, video)
      entry = Enum.find(Library.entries(ctx.alice), &(&1.feed.kind == :youtube))
      {:ok, _} = Library.favourite(ctx.alice, entry.id, true)
      Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [short: true])

      assert [%{id: id}] = Library.entries(ctx.alice, %{"status" => "favourites"})
      assert id == entry.id
    end

    # An entry kept only by its star leaves the library when removed.
    test "removing an entry kept only by its star takes the star off", ctx do
      {:ok, _} = Library.favourite(ctx.alice, ctx.entry.id, true)
      {:ok, _} = Library.unsubscribe(ctx.alice, ctx.subscription.id)

      assert {:ok, _} = Library.remove_entry(ctx.alice, ctx.entry.id)
      assert Library.entries(ctx.alice) == []
    end

    # A subscription keeps the entry listed, so removing the saved row leaves the star.
    test "removing a saved entry of a followed source keeps its star", ctx do
      external_id = hd(ctx.preview.entries).external_id
      {:ok, _} = Library.save(ctx.alice, ctx.preview, external_id, :inbox)
      {:ok, _} = Library.favourite(ctx.alice, ctx.entry.id, true)

      assert {:ok, _} = Library.remove_entry(ctx.alice, ctx.entry.id)
      assert [%{favourite: true}] = Library.entries(ctx.alice)
    end

    # A starred entry stays where the account put it, as a saved one does.
    test "subscribing again leaves a starred entry where it was", ctx do
      {:ok, _} = Playback.mark(ctx.alice, ctx.entry.id, :archived)
      {:ok, _} = Library.favourite(ctx.alice, ctx.entry.id, true)
      {:ok, _} = Library.unsubscribe(ctx.alice, ctx.subscription.id)

      {:ok, _} = Library.subscribe(ctx.alice, ctx.preview, existing: :all, delivery: :queue)
      assert Playback.queue(ctx.alice) == []
      assert [%{playback: %{status: :archived}}] = Library.entries(ctx.alice)
    end

    # Removing a singly saved item leaves the library, so its star goes with it.
    test "removing a saved entry removes its star", ctx do
      {:ok, _} = Library.unsubscribe(ctx.alice, ctx.subscription.id)
      external_id = hd(ctx.preview.entries).external_id
      {:ok, entry} = Library.save(ctx.alice, ctx.preview, external_id, :inbox)
      {:ok, _} = Library.favourite(ctx.alice, entry.id, true)

      assert {:ok, _} = Library.remove_entry(ctx.alice, entry.id)
      assert Library.entries(ctx.alice) == []

      {:ok, _} = Library.save(ctx.alice, ctx.preview, external_id, :inbox)
      assert [%{favourite: false}] = Library.entries(ctx.alice)
    end
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

      # A source counts its unfinished items: the heard podcast no longer, the started video still.
      assert counts.sources == %{
               entries.podcast.feed_id => 0,
               entries.youtube.feed_id => 1,
               entries.peertube.feed_id => 1
             }
    end

    # Unfinished means new or in progress, queued or not. Heard and archived items are not.
    test "a source's unfinished items are new or in progress, queued or not", ctx do
      entries = ctx.entries
      {:ok, _} = Playback.mark(ctx.alice, entries.podcast.id, :archived)
      {:ok, _} = Playback.start(ctx.alice, entries.youtube.id)
      {:ok, _} = Playback.enqueue(ctx.alice, entries.peertube.id, :last)

      counts = ctx.alice |> Library.counts() |> Library.tally(%{})

      assert counts.sources == %{
               entries.podcast.feed_id => 0,
               entries.youtube.feed_id => 1,
               entries.peertube.feed_id => 1
             }

      for {kind, shown} <- [
            podcast: [],
            youtube: [entries.youtube.id],
            peertube: [entries.peertube.id]
          ] do
        filters = %{"source" => to_string(entries[kind].feed_id), "status" => "open"}
        assert Enum.map(Library.entries(ctx.alice, filters), & &1.id) == shown

        assert Library.total(Library.tally(Library.counts(ctx.alice), filters), filters) ==
                 length(shown)
      end
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
                 open: 0,
                 favourites: 0,
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
