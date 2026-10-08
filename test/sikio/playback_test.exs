# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PlaybackTest do
  @moduledoc false
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback

  setup do
    alice = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), feed_url())
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

  # The card's player can seek before the audio loads. `start/3` then begins at that position,
  # also for a heard entry. A negative or non-numeric position falls back to 0.
  test "a start may name the place to begin at", c do
    assert {:ok, %{position: 600.0}} = Playback.start(c.alice, c.entry.id, 600)

    {:ok, _} = Playback.mark(c.alice, c.entry.id, :heard)
    assert {:ok, %{position: 90.0, status: :heard}} = Playback.start(c.alice, c.entry.id, 90)

    assert {:ok, %{position: +0.0}} = Playback.start(c.alice, c.entry.id, -5)
    assert {:ok, %{position: +0.0}} = Playback.start(c.alice, c.entry.id, "soon")
  end

  test "only subscribed accounts may read or write an entry", c do
    assert Library.entry(c.bob, c.entry.id) == nil
    assert {:error, :not_found} = Playback.start(c.bob, c.entry.id)
    assert {:error, :not_found} = Playback.mark(c.bob, c.entry.id, :heard)
    assert {:error, :not_found} = Playback.start(c.alice, "bad")
    {:ok, state} = Playback.start(c.alice, c.entry.id)
    assert {:error, :stale} = Playback.save(c.bob, c.entry.id, state.session_id, sample(1, 20))
    {:ok, _} = Library.unsubscribe(c.alice, c.sub.id)
    assert {:error, :stale} = Playback.save(c.alice, c.entry.id, state.session_id, sample(1, 20))
    assert {:error, :stale} = Playback.stop(c.alice, c.entry.id, state.session_id)
  end

  test "a new player and explicit marks invalidate old events; sequence prevents rewinds", c do
    {:ok, old} = Playback.start(c.alice, c.entry.id)
    {:ok, current} = Playback.start(c.alice, c.entry.id)
    assert {:error, :stale} = Playback.save(c.alice, c.entry.id, old.session_id, sample(100, 90))
    assert {:ok, _} = Playback.save(c.alice, c.entry.id, current.session_id, sample(2, 50))

    assert {:error, :stale} =
             Playback.save(c.alice, c.entry.id, current.session_id, sample(1, 10))

    # A backward seek with a higher sequence number is accepted.
    assert {:ok, %{position: 10.0}} =
             Playback.save(c.alice, c.entry.id, current.session_id, sample(3, 10))

    assert {:ok, %{status: :heard, completed_at: %DateTime{}}} =
             Playback.mark(c.alice, c.entry.id, :heard)

    assert {:error, :stale} =
             Playback.save(c.alice, c.entry.id, current.session_id, sample(4, 20))

    assert {:ok, %{status: :new, position: +0.0, completed_at: nil}} =
             Playback.mark(c.alice, c.entry.id, :new)
  end

  # A long episode counts as heard in its last minute, which skips end credits.
  test "a long item is heard in its last minute, not at 90 %", c do
    {:ok, state} = Playback.start(c.alice, c.entry.id)
    hour = &%{sample(&1, &2) | "duration" => 3600}

    assert {:ok, %{status: :in_progress}} =
             Playback.save(c.alice, c.entry.id, state.session_id, hour.(1, 3539))

    assert {:ok, %{status: :heard}} =
             Playback.save(c.alice, c.entry.id, state.session_id, hour.(2, 3540))
  end

  # An item under ten minutes counts as heard at 90 %, later than its last minute.
  # Replaying a heard entry keeps it heard.
  test "a short item played to 90 % is heard, and stays heard when played again", c do
    {:ok, state} = Playback.start(c.alice, c.entry.id)

    assert {:ok, %{status: :in_progress}} =
             Playback.save(c.alice, c.entry.id, state.session_id, sample(1, 89))

    assert {:ok, %{status: :heard, completed_at: %DateTime{}}} =
             Playback.save(c.alice, c.entry.id, state.session_id, sample(2, 90))

    {:ok, replay} = Playback.start(c.alice, c.entry.id)
    assert replay.position == 0

    assert {:ok, %{status: :heard}} =
             Playback.save(c.alice, c.entry.id, replay.session_id, sample(1, 10))

    assert %{playback: %{status: :heard}} = Library.entry(c.alice, c.entry.id)
  end

  # An `ended` sample marks the entry heard when the duration is unknown.
  test "an item played to its end is heard without a length", c do
    {:ok, state} = Playback.start(c.alice, c.entry.id)
    ended = %{sample(1, 30) | "duration" => nil} |> Map.put("ended", true)

    assert {:ok, %{status: :heard}} = Playback.save(c.alice, c.entry.id, state.session_id, ended)
  end

  # Manual marks: heard, archived, or new with the position reset. Each removes the entry from
  # the queue.
  test "an item is marked heard, archived or new by hand, and leaves the queue", c do
    for status <- [:heard, :archived, :new] do
      {:ok, _} = Playback.enqueue(c.alice, c.entry.id, :last)
      {:ok, %{session_id: session}} = Playback.start(c.alice, c.entry.id)
      {:ok, _} = Playback.save(c.alice, c.entry.id, session, sample(1, 50))

      assert {:ok, marked} = Playback.mark(c.alice, c.entry.id, status)
      assert marked.status == status
      assert marked.queue_rank == nil
      assert marked.position == if(status == :new, do: 0.0, else: 50.0)
      assert marked.completed_at != nil == (status != :new)
    end
  end

  # A moved item lands at the target index, and the others keep their relative order.
  # An index past the end moves it to the end.
  test "an item moves to a place in the queue", c do
    entries =
      for n <- 1..4, do: %{hd(c.preview.entries) | external_id: "m#{n}", title: "Moved #{n}"}

    {:ok, _} = Library.subscribe(c.alice, %{c.preview | entries: entries})
    id = &Repo.one!(from e in Entry, where: e.title == ^"Moved #{&1}", select: e.id)
    for n <- 1..4, do: {:ok, _} = Playback.enqueue(c.alice, id.(n), :last)

    {:ok, _} = Playback.move(c.alice, id.(4), 1)
    assert Playback.queue(c.alice) == [id.(1), id.(4), id.(2), id.(3)]

    {:ok, _} = Playback.move(c.alice, id.(1), 2)
    assert Playback.queue(c.alice) == [id.(4), id.(2), id.(1), id.(3)]

    {:ok, _} = Playback.move(c.alice, id.(3), 0)
    assert Playback.queue(c.alice) == [id.(3), id.(4), id.(2), id.(1)]

    {:ok, _} = Playback.move(c.alice, id.(3), 99)
    assert Playback.queue(c.alice) == [id.(4), id.(2), id.(1), id.(3)]

    assert {:error, :not_queued} = Playback.move(c.alice, c.entry.id, 0)
    assert {:error, :not_found} = Playback.move(c.bob, id.(1), 0)
  end

  # The player follows the queue list order, so both must break rank ties the same way.
  test "the queue plays in the order it is shown when two ranks are equal", c do
    entries =
      for n <- 1..2, do: %{hd(c.preview.entries) | external_id: "t#{n}", title: "Tie #{n}"}

    {:ok, _} = Library.subscribe(c.alice, %{c.preview | entries: entries})
    id = &Repo.one!(from e in Entry, where: e.title == ^"Tie #{&1}", select: e.id)

    # Enqueued in reverse, so playback row order differs from entry order.
    for n <- [2, 1], do: {:ok, _} = Playback.enqueue(c.alice, id.(n), :last)
    Repo.update_all(Playback.State, set: [queue_rank: 1.0])

    shown = Enum.map(Library.entries(c.alice, %{"status" => "queue"}), & &1.id)
    assert Playback.queue(c.alice) == shown
  end

  # Each move into the same slot halves the rank gap. After enough moves no float fits between
  # the neighbours, which forces a renumbering.
  test "an item moved into the same place again and again keeps its place", c do
    entries =
      for n <- 1..3, do: %{hd(c.preview.entries) | external_id: "h#{n}", title: "Half #{n}"}

    {:ok, _} = Library.subscribe(c.alice, %{c.preview | entries: entries})
    id = &Repo.one!(from e in Entry, where: e.title == ^"Half #{&1}", select: e.id)
    for n <- 1..3, do: {:ok, _} = Playback.enqueue(c.alice, id.(n), :last)

    for _ <- 1..60 do
      [first, _second, last] = Playback.queue(c.alice)
      {:ok, _} = Playback.move(c.alice, last, 1)
      assert [^first, ^last, _] = Playback.queue(c.alice)
    end
  end

  # Queue changes alter what lists show, so they broadcast `:playback_changed` like a status
  # change does.
  test "a change to the queue is announced as a change, not as progress", c do
    Events.subscribe(c.alice)
    {:ok, _} = Playback.enqueue(c.alice, c.entry.id, :last)
    assert_received {:playback_changed, %{queue_rank: rank}} when is_number(rank)
    {:ok, _} = Playback.move(c.alice, c.entry.id, 0)
    assert_received {:playback_changed, _}
    {:ok, _} = Playback.dequeue(c.alice, c.entry.id)
    assert_received {:playback_changed, %{queue_rank: nil}}
  end

  # As in Castro, playing an item moves it to the queue head, unless it is already queued.
  test "playing an item queues it first, and leaves a queued one where it is", c do
    entries =
      for n <- 1..2, do: %{hd(c.preview.entries) | external_id: "p#{n}", title: "Played #{n}"}

    {:ok, _} = Library.subscribe(c.alice, %{c.preview | entries: entries})
    id = &Repo.one!(from e in Entry, where: e.title == ^&1, select: e.id)

    {:ok, _} = Playback.enqueue(c.alice, id.("Played 1"), :last)
    {:ok, _} = Playback.enqueue(c.alice, id.("Played 2"), :last)
    {:ok, _} = Playback.start(c.alice, c.entry.id)
    assert Playback.queue(c.alice) == [c.entry.id, id.("Played 1"), id.("Played 2")]

    {:ok, _} = Playback.start(c.alice, id.("Played 2"))
    assert Playback.queue(c.alice) == [c.entry.id, id.("Played 1"), id.("Played 2")]
  end

  # Playing an archived entry sets it back to `in_progress`.
  test "an archived item played again is in progress", c do
    {:ok, _} = Playback.mark(c.alice, c.entry.id, :archived)
    {:ok, %{session_id: session}} = Playback.start(c.alice, c.entry.id)

    assert {:ok, %{status: :in_progress, completed_at: nil}} =
             Playback.save(c.alice, c.entry.id, session, sample(1, 10))
  end

  # `:first` enqueues at the head and `:last` at the tail.
  test "the queue takes an item first or last and lets it go", c do
    entries =
      for n <- 1..3, do: %{hd(c.preview.entries) | external_id: "q#{n}", title: "Queued #{n}"}

    {:ok, _} = Library.subscribe(c.alice, %{c.preview | entries: entries})
    id = &Repo.one!(from e in Entry, where: e.title == ^&1, select: e.id)

    {:ok, _} = Playback.enqueue(c.alice, id.("Queued 1"), :last)
    {:ok, _} = Playback.enqueue(c.alice, id.("Queued 2"), :last)
    {:ok, _} = Playback.enqueue(c.alice, id.("Queued 3"), :first)

    assert Playback.queue(c.alice) == [id.("Queued 3"), id.("Queued 1"), id.("Queued 2")]
    assert Playback.queue(c.bob) == []

    {:ok, %{queue_rank: nil}} = Playback.dequeue(c.alice, id.("Queued 1"))
    assert Playback.queue(c.alice) == [id.("Queued 3"), id.("Queued 2")]

    assert {:error, :not_found} = Playback.enqueue(c.bob, id.("Queued 1"), :last)
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

  # Every write checks ownership, and players send a sample at least every five seconds.
  # The check queries `subscriptions` and never `feeds`. A save issues a single SELECT.
  # On Postgres that SELECT takes the row lock. SQLite locks the database at transaction start.
  test "a write checks ownership without loading the item", c do
    {{:ok, %{session_id: session}}, started} =
      queries(fn -> Playback.start(c.alice, c.entry.id) end)

    {{:ok, _}, saved} =
      queries(fn -> Playback.save(c.alice, c.entry.id, session, sample(1, 9)) end)

    assert started != [] and saved != []
    refute Enum.any?(started ++ saved, &(&1 =~ ~s("feeds")))
    assert [lock] = Enum.filter(saved, &String.starts_with?(&1, "SELECT"))
    assert lock =~ ~s("subscriptions")

    if Application.fetch_env!(:sikio, :database) == :postgres,
      do: assert(lock =~ ~r/FOR UPDATE$/)
  end

  # `mark_all` archives every entry the filter matches, across all pages, for this account only.
  # Archived entries stay out of the history. Options exclude in-progress entries and the
  # entry in the reader's player. Without options, a leftover session excludes nothing.
  test "mark_all archives what a list shows, leaving out only what it is asked to", c do
    entries =
      for n <- 1..120,
          do: %{hd(c.preview.entries) | external_id: "e#{n}", title: "Episode #{n}"}

    {:ok, _} = Library.subscribe(c.alice, %{c.preview | entries: entries})
    {:ok, _} = Library.subscribe(c.bob, %{c.preview | entries: entries})

    id = fn title ->
      Repo.one!(from e in Entry, where: e.title == ^title, select: e.id)
    end

    {:ok, _} = Playback.start(c.alice, id.("Episode 5"))
    {:ok, %{session_id: session}} = Playback.start(c.alice, id.("Episode 6"))
    {:ok, _} = Playback.save(c.alice, id.("Episode 6"), session, sample(1, 30))
    {:ok, _} = Playback.mark(c.alice, id.("Episode 7"), :heard)
    Events.subscribe(c.alice)

    # The query "episode 11" matches Episode 11 and Episodes 110 to 119.
    assert {:ok, 11} = Playback.mark_all(c.alice, %{"q" => "episode 11"})
    assert_received {:playback_marked, 11}

    options = [in_progress: false, keep: id.("Episode 5")]
    unfinished = Library.count(c.alice, %{"status" => ""}) - 12
    assert Playback.markable(c.alice, %{"status" => ""}, options) == unfinished - 2
    assert {:ok, marked} = Playback.mark_all(c.alice, %{"status" => ""}, options)
    assert marked == unfinished - 2

    left =
      Library.entries(c.alice, %{"status" => "new"}) ++
        Library.entries(c.alice, %{"status" => "in_progress"})

    assert Enum.map(left, & &1.title) |> Enum.sort() == ["Episode 5", "Episode 6"]

    # Without options, the leftover session on Episode 5 does not exclude it.
    assert Playback.markable(c.alice, %{"status" => ""}) == 2
    assert {:ok, 2} = Playback.mark_all(c.alice, %{"status" => ""})

    statuses =
      Repo.all(from p in Playback.State, where: p.user_id == ^c.alice.id, select: p.status)

    assert Enum.frequencies(statuses) == %{heard: 1, archived: Library.count(c.alice, %{}) - 1}
    assert Library.count(c.alice, %{"status" => "completed"}) == 1
    assert Repo.aggregate(from(p in Playback.State, where: p.user_id == ^c.bob.id), :count) == 0
  end

  defp sample(sequence, position),
    do: %{"sequence" => sequence, "position" => position, "duration" => 100, "ended" => false}
end
