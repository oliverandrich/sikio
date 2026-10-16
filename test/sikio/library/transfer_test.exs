# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.TransferTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo
  import Sikio.FeedFixtures
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Library.Transfer
  alias Sikio.Library.TransferImport
  alias Sikio.Playback
  alias Sikio.Preferences
  alias Sikio.Tags

  describe "export" do
    setup do
      user = account()
      url = feed_url()
      {:ok, preview} = Parser.parse(podcast_later(), url)
      {:ok, sub} = Library.subscribe(user, preview, existing: :all)

      {:ok, _} =
        Library.configure(user, sub.id, %{name: "Late nights", delivery: :queue}, ["Evening"])

      [later, first] = Library.entries(user)
      {:ok, _} = Playback.mark(user, first.id, :heard)
      {:ok, _} = Library.favourite(user, first.id, true)
      {:ok, _} = Playback.enqueue(user, later.id, :last)

      # A singly saved episode from a source the account does not follow.
      saved_url = feed_url()
      {:ok, other} = Parser.parse(podcast("Elsewhere"), saved_url)
      {:ok, _} = Library.save(user, other, "episode-1", :inbox)

      {:ok, _} = Preferences.update(user, %{play_on: false, locale: "de"})
      %{user: user, url: url, saved_url: saved_url}
    end

    test "carries subscriptions, tags and preferences", c do
      document = Transfer.export(c.user)

      assert %{format: "sikio-account", version: 1} = document

      assert %{play_on: false, start_view: "queue", start_tag: nil, locale: "de"} =
               document.preferences

      assert [
               %{
                 url: url,
                 kind: :podcast,
                 title: "Small Hours",
                 name: "Late nights",
                 paused: false,
                 delivery: :queue,
                 shorts: false,
                 tags: ["Evening"]
               }
             ] = document.subscriptions

      assert url == c.url
    end

    test "references entries by feed, external id and page, with the account's state", c do
      entries = Map.new(Transfer.export(c.user).entries, &{{&1.feed_url, &1.external_id}, &1})

      assert %{
               status: :heard,
               favourite: true,
               saved: false,
               queue: nil,
               page_url: "https://example.org/episodes/1",
               title: "One & two"
             } = entries[{c.url, "episode-1"}]

      assert %DateTime{} = entries[{c.url, "episode-1"}].completed_at
      assert %{status: :new, queue: 1, favourite: false} = entries[{c.url, "episode-2"}]
      assert %{status: :new, saved: true, queue: nil} = entries[{c.saved_url, "episode-1"}]
      assert map_size(entries) == 3
    end

    test "leaves out another account's library", c do
      other = account()
      {:ok, preview} = Parser.parse(podcast(), feed_url())
      {:ok, _} = Library.subscribe(other, preview)

      assert %{subscriptions: [], entries: []} = Transfer.export(account())
      assert length(Transfer.export(c.user).subscriptions) == 1
    end

    test "omits archived entries the account neither starred nor saved", c do
      url = feed_url()
      {:ok, preview} = Parser.parse(podcast_later(), url)
      {:ok, sub} = Library.subscribe(c.user, preview, existing: :all)

      later =
        Enum.find(Library.entries(c.user), &(&1.feed_id == sub.feed_id and &1.title == "Later"))

      {:ok, _} = Playback.mark(c.user, later.id, :archived)

      external_ids =
        for e <- Transfer.export(c.user).entries, e.feed_url == url, do: e.external_id

      assert external_ids == ["episode-1"]
    end
  end

  describe "export of long values" do
    test "stays within what an import reads" do
      user = account()
      {:ok, preview} = Parser.parse(podcast(), feed_url())
      {:ok, _} = Library.subscribe(user, preview)
      Repo.update_all(Entry, set: [title: String.duplicate("ä", 3000)])

      assert {:ok, %{entries: [entry]}} =
               user |> Transfer.export() |> Jason.encode!() |> Transfer.parse()

      assert byte_size(entry.title) <= 2048
      assert String.valid?(entry.title)
    end
  end

  describe "parse" do
    test "reads an export back with atoms and dates" do
      user = account()
      {:ok, preview} = Parser.parse(podcast(), feed_url())
      {:ok, _} = Library.subscribe(user, preview)
      [entry] = Library.entries(user)
      {:ok, _} = Playback.mark(user, entry.id, :heard)
      exported = Transfer.export(user)

      assert {:ok, document} = exported |> Jason.encode!() |> Transfer.parse()
      assert document.subscriptions == exported.subscriptions
      assert document.preferences == exported.preferences
      assert [%{status: :heard, completed_at: %DateTime{}}] = document.entries
      assert document.entries == exported.entries
    end

    test "refuses another format, another version and malformed JSON" do
      assert {:error, :invalid_document} = Transfer.parse("{")
      assert {:error, :invalid_document} = Transfer.parse(~s({"format": "opml", "version": 1}))

      assert {:error, {:unsupported_version, 2}} =
               Transfer.parse(~s({"format": "sikio-account", "version": 2}))
    end

    test "refuses an oversized file and values outside their range" do
      assert {:error, :too_large} = Transfer.parse(String.duplicate(" ", 5_000_001))

      assert {:error, :invalid_document} =
               document(subscriptions: [subscription(%{"delivery" => "everywhere"})])

      assert {:error, :invalid_document} =
               document(entries: [entry(%{"status" => "loved"})])

      assert {:error, :invalid_document} = document(entries: [entry(%{"position" => -1})])
      assert {:error, :invalid_document} = document(entries: [entry(%{"completed_at" => "soon"})])
    end

    test "refuses more subscriptions or entries than an import handles" do
      many = for _n <- 1..501, do: subscription(%{"url" => feed_url()})
      assert {:error, :too_many_subscriptions} = document(subscriptions: many)

      many = for n <- 1..20_001, do: entry(%{"external_id" => "#{n}"})
      assert {:error, :too_many_entries} = document(entries: many)
    end
  end

  describe "restore" do
    setup do
      alice = account()
      url = feed_url("later")
      saved_url = feed_url("saved")

      # The stub matches on the request path only, so each fixture feed has its own path.
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/later" ->
            Plug.Conn.send_resp(conn, 200, podcast_later())

          "/saved" ->
            Plug.Conn.send_resp(conn, 200, podcast())

          "/alias" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/later")
            |> Plug.Conn.send_resp(301, "")

          _down ->
            Plug.Conn.send_resp(conn, 503, "down")
        end
      end)

      {:ok, preview} = Parser.parse(podcast_later(), url)
      {:ok, sub} = Library.subscribe(alice, preview, existing: :all)
      {:ok, _} = Library.configure(alice, sub.id, %{name: "Late nights"}, ["Evening"])
      {:ok, _} = Library.pause(alice, sub.id, true)
      [later, first] = Library.entries(alice)
      {:ok, _} = Playback.mark(alice, first.id, :heard)
      {:ok, _} = Library.favourite(alice, first.id, true)
      {:ok, _} = Playback.enqueue(alice, later.id, :last)
      {:ok, other} = Parser.parse(podcast(), saved_url)
      {:ok, _} = Library.save(alice, other, "episode-1", :inbox)
      {:ok, _} = Preferences.update(alice, %{play_on: false, locale: "de"})

      %{document: Transfer.export(alice), url: url, saved_url: saved_url}
    end

    test "rebuilds subscriptions, states, stars, saved entries and preferences", c do
      bob = account()
      summary = Transfer.restore(bob, c.document)

      assert %{subscriptions: %{imported: 1, existing: 0, failed: []}} = summary
      assert %{entries: %{restored: 3, missing: 0}} = summary

      assert [%{name: "Late nights", paused: true, feed: %{url: url}}] =
               Library.subscriptions(bob)

      assert url == c.url
      assert [%{name: "Evening"}] = Tags.list(bob)

      entries = Library.entries(bob, %{"status" => ""})
      first = Enum.find(entries, &(&1.title == "One & two" and &1.feed.url == c.url))
      later = Enum.find(entries, &(&1.title == "Later"))
      assert %{status: :heard, completed_at: %DateTime{}} = first.playback
      assert first.favourite
      assert Playback.queue(bob) == [later.id]
      assert Enum.any?(entries, &(&1.feed.url == c.saved_url))
      assert %{play_on: false, locale: "de"} = Preferences.get(bob)
    end

    test "keeps what the account already has and adds the rest", c do
      bob = account()
      {:ok, preview} = Parser.parse(podcast_later(), c.url)
      {:ok, sub} = Library.subscribe(bob, preview, existing: :all)
      {:ok, _} = Library.configure(bob, sub.id, %{name: "Mine"}, ["Own"])
      first = Enum.find(Library.entries(bob), &(&1.title == "One & two"))
      {:ok, _} = Playback.mark(bob, first.id, :archived)
      {:ok, _} = Preferences.update(bob, %{play_on: true})

      assert %{subscriptions: %{imported: 0, existing: 1}, entries: entries} =
               Transfer.restore(bob, c.document)

      # The archived episode keeps its state. The queued one has none here and joins the queue.
      assert %{restored: 2, kept: 1, missing: 0} = entries
      later = Enum.find(Library.entries(bob, %{"status" => ""}), &(&1.title == "Later"))
      assert Playback.queue(bob) == [later.id]
      assert [%{name: "Mine"}] = Library.subscriptions(bob)
      assert bob |> Tags.list() |> Enum.map(& &1.name) |> Enum.sort() == ["Evening", "Own"]
      assert %{playback: %{status: :archived}} = Library.entry(bob, first.id)
      assert %{play_on: true} = Preferences.get(bob)
    end

    # The URL in the file leads to a feed the account follows under its final address.
    test "keeps a subscription the file names under another address", c do
      bob = account()
      {:ok, preview} = Parser.parse(podcast_later(), c.url)
      {:ok, sub} = Library.subscribe(bob, preview)
      {:ok, _} = Library.configure(bob, sub.id, %{name: "Mine"}, [])
      alias_url = String.replace(c.url, "/later", "/alias")

      document =
        Map.update!(c.document, :subscriptions, &Enum.map(&1, fn s -> %{s | url: alias_url} end))

      assert %{subscriptions: %{imported: 0, existing: 1}} = Transfer.restore(bob, document)
      assert [%{name: "Mine", paused: false}] = Library.subscriptions(bob)
    end

    test "finds entries of a source the account follows although the file does not", c do
      bob = account()
      {:ok, preview} = Parser.parse(podcast(), c.saved_url)
      {:ok, _} = Library.subscribe(bob, preview)
      document = %{c.document | subscriptions: []}

      assert %{entries: %{missing: 0}} = Transfer.restore(bob, document)
      assert Enum.any?(Library.entries(bob), &(&1.feed.url == c.saved_url))
    end

    test "counts a source that cannot be fetched and goes on with the others", c do
      bob = account()
      down = feed_url("down")
      document = Map.update!(c.document, :subscriptions, &[%{hd(&1) | url: down} | &1])

      assert %{subscriptions: %{imported: 1, failed: [^down]}} = Transfer.restore(bob, document)
    end

    # Entries belong to shared feeds. A file must not add episodes other members would see.
    test "never creates an entry from the file's own data", c do
      bob = account()
      planted = %{hd(c.document.entries) | external_id: "planted", page_url: nil, status: :new}
      document = Map.update!(c.document, :entries, &[planted | &1])

      assert %{entries: %{missing: 1}} = Transfer.restore(bob, document)
      refute Repo.exists?(from e in Entry, where: e.external_id == "planted")
    end

    test "finds a queued video that left its feed through its page, and drops old history" do
      # oEmbed names the channel, so the restored video lands in the subscribed feed.
      channel = youtube_feed_url()
      channel_id = URI.decode_query(URI.parse(channel).query)["channel_id"]

      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/oembed" ->
            Req.Test.json(conn, %{
              title: "An old video",
              author_url: "https://www.youtube.com/channel/#{channel_id}"
            })

          "/feeds/videos.xml" ->
            Plug.Conn.send_resp(conn, 200, youtube())

          _page ->
            Plug.Conn.send_resp(conn, 200, "<html></html>")
        end
      end)

      gone = fn id, status, queue ->
        %{
          feed_url: channel,
          external_id: "yt:video:#{id}",
          page_url: "https://www.youtube.com/watch?v=#{id}",
          title: "An old video",
          status: status,
          position: 0.0,
          duration: nil,
          completed_at: nil,
          queue: queue,
          favourite: false,
          saved: false
        }
      end

      document = %{
        format: "sikio-account",
        version: 1,
        preferences: %{play_on: true, start_view: "queue", start_tag: nil, locale: nil},
        subscriptions: [
          %{
            url: channel,
            kind: :youtube,
            title: nil,
            name: nil,
            paused: false,
            delivery: :inbox,
            shorts: false,
            tags: []
          }
        ],
        entries: [gone.("zzzzzzzzzzz", :new, 1), gone.("yyyyyyyyyyy", :heard, nil)]
      }

      bob = account()
      assert %{entries: %{restored: 1, missing: 1}} = Transfer.restore(bob, document)
      assert [id] = Playback.queue(bob)
      assert %{video_id: "zzzzzzzzzzz"} = Library.entry(bob, id)
    end
  end

  describe "restore through a page" do
    # The page leads to an entry this instance already holds, with the account's own state.
    test "keeps the state of an entry the page look-up finds" do
      channel = youtube_feed_url()
      channel_id = URI.decode_query(URI.parse(channel).query)["channel_id"]

      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/oembed" ->
            Req.Test.json(conn, %{
              title: "A good video",
              author_url: "https://www.youtube.com/channel/#{channel_id}"
            })

          "/feeds/videos.xml" ->
            Plug.Conn.send_resp(conn, 200, youtube())

          _other ->
            Plug.Conn.send_resp(conn, 503, "down")
        end
      end)

      bob = account()
      {:ok, preview} = Parser.parse(youtube(), channel)
      {:ok, _} = Library.subscribe(bob, preview)
      [video] = Library.entries(bob)
      {:ok, _} = Playback.mark(bob, video.id, :heard)

      document = %{
        format: "sikio-account",
        version: 1,
        preferences: %{play_on: true, start_view: "queue", start_tag: nil, locale: nil},
        subscriptions: [],
        entries: [
          %{
            feed_url: feed_url("down"),
            external_id: video.external_id,
            page_url: "https://www.youtube.com/watch?v=abcdefghijk",
            title: "A good video",
            status: :new,
            position: 0.0,
            duration: nil,
            completed_at: nil,
            queue: 1,
            favourite: false,
            saved: true
          }
        ]
      }

      assert %{entries: %{kept: 1}} = Transfer.restore(bob, document)
      assert %{playback: %{status: :heard}} = Library.entry(bob, video.id)
      assert Playback.queue(bob) == []
    end
  end

  describe "start" do
    test "checks the file at once and imports it in the background" do
      bob = account()
      assert {:error, :invalid_document} = Transfer.start(bob, "{")
      refute_enqueued(worker: TransferImport)

      url = feed_url("later")
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast_later()) end)
      json = subscribed_document(url)

      assert {:ok, _job} = Transfer.start(bob, json)
      assert {:error, :already_running} = Transfer.start(bob, json)
      # Its own queue keeps a long import from holding a slot that polling needs.
      assert [job] = all_enqueued(worker: TransferImport, queue: :imports)

      Events.subscribe_imports(bob)
      assert :ok = perform_job(TransferImport, job.args)
      assert_receive {:library_imported, {:ok, %{subscriptions: %{imported: 1}}}}
      assert [%{feed: %{url: ^url}}] = Library.subscriptions(bob)
    end
  end

  defp subscribed_document(url) do
    Jason.encode!(%{
      "format" => "sikio-account",
      "version" => 1,
      "preferences" => %{"play_on" => true, "start_view" => "queue"},
      "subscriptions" => [subscription(%{"url" => url})],
      "entries" => []
    })
  end

  defp document(parts) do
    %{
      "format" => "sikio-account",
      "version" => 1,
      "preferences" => %{"play_on" => true, "start_view" => "queue"},
      "subscriptions" => Keyword.get(parts, :subscriptions, []),
      "entries" => Keyword.get(parts, :entries, [])
    }
    |> Jason.encode!()
    |> Transfer.parse()
  end

  defp subscription(attrs) do
    Map.merge(
      %{
        "url" => "https://example.org/feed",
        "paused" => false,
        "delivery" => "inbox",
        "shorts" => false,
        "tags" => []
      },
      attrs
    )
  end

  defp entry(attrs) do
    Map.merge(
      %{
        "feed_url" => "https://example.org/feed",
        "external_id" => "episode-1",
        "status" => "new",
        "favourite" => false,
        "saved" => false
      },
      attrs
    )
  end

  defp account, do: Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
end
