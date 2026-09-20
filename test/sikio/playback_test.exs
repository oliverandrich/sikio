# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PlaybackTest do
  @moduledoc false
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback

  setup do
    alice = Repo.insert!(User.changeset(%User{}, %{username: "alice"}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: "bob"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, sub} = Library.subscribe(alice, preview)
    [entry] = Library.entries(alice)
    %{alice: alice, bob: bob, entry: entry, preview: preview, sub: sub}
  end

  test "progress resumes per account and survives feed refresh", c do
    assert {:ok, first} = Playback.start(c.alice, c.entry.id)
    assert first.position == 0

    assert {:ok, %{status: :in_progress, position: 42.5}} =
             Playback.save(c.alice, c.entry.id, first.session_id, sample(1, 42.5))

    assert {:ok, _} = Feeds.store(c.preview)
    assert {:ok, resumed} = Playback.start(c.alice, c.entry.id)
    assert resumed.position == 42.5
    assert resumed.session_id != first.session_id
    {:ok, _} = Library.subscribe(c.bob, c.preview)
    assert {:ok, %{position: +0.0, status: :new}} = Playback.start(c.bob, c.entry.id)
  end

  test "only subscribed accounts may read or write an entry", c do
    assert Library.entry(c.bob, c.entry.id) == nil
    assert {:error, :not_found} = Playback.start(c.bob, c.entry.id)
    assert {:error, :not_found} = Playback.mark(c.bob, c.entry.id, :completed)
    assert {:error, :not_found} = Playback.start(c.alice, "bad")
    {:ok, state} = Playback.start(c.alice, c.entry.id)
    assert {:error, :stale} = Playback.save(c.bob, c.entry.id, state.session_id, sample(1, 20))
    {:ok, _} = Library.unsubscribe(c.alice, c.sub.id)
    assert {:error, :stale} = Playback.save(c.alice, c.entry.id, state.session_id, sample(1, 20))
  end

  test "a new player and explicit marks invalidate old events; sequence prevents rewinds", c do
    {:ok, old} = Playback.start(c.alice, c.entry.id)
    {:ok, current} = Playback.start(c.alice, c.entry.id)
    assert {:error, :stale} = Playback.save(c.alice, c.entry.id, old.session_id, sample(100, 90))
    assert {:ok, _} = Playback.save(c.alice, c.entry.id, current.session_id, sample(2, 50))

    assert {:error, :stale} =
             Playback.save(c.alice, c.entry.id, current.session_id, sample(1, 10))

    # A later deliberate seek backwards is valid.
    assert {:ok, %{position: 10.0}} =
             Playback.save(c.alice, c.entry.id, current.session_id, sample(3, 10))

    assert {:ok, %{status: :completed, completed_at: %DateTime{}}} =
             Playback.mark(c.alice, c.entry.id, :completed)

    assert {:error, :stale} =
             Playback.save(c.alice, c.entry.id, current.session_id, sample(4, 20))

    assert {:ok, %{status: :new, position: +0.0, completed_at: nil}} =
             Playback.mark(c.alice, c.entry.id, :new)
  end

  test "only an end event completes playback; replay does not undo completion", c do
    {:ok, state} = Playback.start(c.alice, c.entry.id)

    assert {:ok, %{status: :in_progress}} =
             Playback.save(c.alice, c.entry.id, state.session_id, sample(1, 99))

    assert {:ok, %{status: :completed}} =
             Playback.save(
               c.alice,
               c.entry.id,
               state.session_id,
               Map.put(sample(2, 100), "ended", true)
             )

    {:ok, replay} = Playback.start(c.alice, c.entry.id)
    assert replay.position == 0

    assert {:ok, %{status: :completed}} =
             Playback.save(c.alice, c.entry.id, replay.session_id, sample(1, 10))

    assert %{playback: %{status: :completed}} = Library.entry(c.alice, c.entry.id)
  end

  test "malformed or unbounded samples never alter progress", c do
    {:ok, state} = Playback.start(c.alice, c.entry.id)

    for attrs <- [
          sample(1, -1),
          sample(0, 1),
          sample(1, 999_999_999),
          %{},
          Map.put(sample(1, 10), "ended", "yes")
        ] do
      assert {:error, :invalid_progress} =
               Playback.save(c.alice, c.entry.id, state.session_id, attrs)
    end

    assert %{playback: %{position: +0.0}} = Library.entry(c.alice, c.entry.id)
  end

  test "closing a player invalidates only its session and keeps its saved position", c do
    {:ok, state} = Playback.start(c.alice, c.entry.id)
    Playback.save(c.alice, c.entry.id, state.session_id, sample(1, 42))

    assert {:ok, %{session_id: nil, position: 42.0}} =
             Playback.stop(c.alice, c.entry.id, state.session_id)

    assert {:error, :stale} = Playback.save(c.alice, c.entry.id, state.session_id, sample(2, 90))
    {:ok, current} = Playback.start(c.alice, c.entry.id)
    assert {:error, :stale} = Playback.stop(c.alice, c.entry.id, state.session_id)
    assert {:error, :stale} = Playback.stop(c.bob, c.entry.id, current.session_id)
    assert Library.entry(c.alice, c.entry.id).playback.session_id == current.session_id
  end

  defp sample(sequence, position),
    do: %{"sequence" => sequence, "position" => position, "duration" => 100, "ended" => false}
end
