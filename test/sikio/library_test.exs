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
    alice = Repo.insert!(User.changeset(%User{}, %{username: "alice"}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: "bob"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
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
        "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
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
end
