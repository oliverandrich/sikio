# SPDX-License-Identifier: AGPL-3.0-or-later

if Application.compile_env!(:sikio, :database) == :postgres do
  defmodule Sikio.QueueLockTest do
    @moduledoc """
    Tests locking of one account's queue on Postgres, with concurrent connections.

    The sandbox uses one connection, so it cannot test concurrency. This module commits and
    deletes its rows afterwards. SQLite needs no such test, because `IMMEDIATE` transactions take
    the single write lock at start.
    """
    use ExUnit.Case, async: false

    import Ecto.Query
    import Sikio.FeedFixtures

    alias Ecto.Adapters.SQL.Sandbox
    alias Sikio.Accounts.User
    alias Sikio.Feeds.Entry
    alias Sikio.Feeds.Feed
    alias Sikio.Feeds.Parser
    alias Sikio.Library
    alias Sikio.Playback
    alias Sikio.Playback.State
    alias Sikio.Repo

    @username "queue_lock_test"

    # Synchronous modules run after all async ones, so no other test holds a sandbox.
    # Cleanup is registered first and deletes by username and URL.
    # A failed setup therefore leaves no rows.
    setup do
      url = feed_url()
      Sandbox.mode(Repo, :auto)

      on_exit(fn ->
        Sandbox.mode(Repo, :auto)
        Repo.delete_all(from u in User, where: u.username == @username)
        Repo.delete_all(from f in Feed, where: f.url == ^url)
        Sandbox.mode(Repo, :manual)
      end)

      account = Repo.insert!(User.changeset(%User{}, %{username: @username}))
      {:ok, preview} = Parser.parse(podcast(), url)
      {:ok, _sub} = Library.subscribe(account, preview)
      %{account: account, entry: hd(Library.entries(account)), url: url}
    end

    test "a change to the queue waits for another change to the same account's queue", c do
      assert {:ok, %{queue_rank: rank}} =
               waits_for_queue(c.account, fn ->
                 Playback.enqueue(c.account, c.entry.id, :last)
               end)

      assert is_float(rank)
    end

    # `mark_all/2` dequeues many rows at once, while a renumbering may lock some of them.
    test "putting a list aside waits for a change to the queue", c do
      {:ok, _} = Playback.enqueue(c.account, c.entry.id, :last)

      assert {:ok, 1} = waits_for_queue(c.account, fn -> Playback.mark_all(c.account, %{}) end)
    end

    # Dequeuing does not take the queue lock. A concurrent renumbering must not restore an item
    # that another transaction dequeued.
    test "a renumbering leaves out an item taken out of the queue meanwhile", c do
      {:ok, preview} = Parser.parse(podcast(), c.url)

      entries =
        for n <- 1..3, do: %{hd(preview.entries) | external_id: "r#{n}", title: "Rank #{n}"}

      {:ok, _} = Library.subscribe(c.account, %{preview | entries: entries})
      [first, taken, moved] = for n <- 1..3, do: entry_id("Rank #{n}")

      # No float lies between the first two ranks, so moving the third there forces a renumbering.
      for {id, rank} <- [{first, 1.0}, {taken, 1.0000000000000002}, {moved, 3.0}] do
        {:ok, _} = Playback.enqueue(c.account, id, :last)
        Repo.update_all(from(p in State, where: p.entry_id == ^id), set: [queue_rank: rank])
      end

      test = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            {:ok, _} = Playback.dequeue(c.account, taken)
            send(test, :taken)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :taken
      move = Task.async(fn -> Playback.move(c.account, moved, 1) end)

      assert Enum.any?(1..1000, fn _ -> blocked?(~s(UPDATE "playback_states")) end),
             "the renumbering did not wait for the item"

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder)
      assert {:ok, _} = Task.await(move)

      assert Playback.queue(c.account) == [first, moved]
    end

    defp entry_id(title), do: Repo.one!(from e in Entry, where: e.title == ^title, select: e.id)

    # Holds the queue lock in another transaction, then runs `change`. Asserts via
    # `pg_stat_activity` that `change` waits until the lock is released.
    defp waits_for_queue(account, change) do
      test = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Library.lock_queue(account.id)
            send(test, :held)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :held
      task = Task.async(change)

      assert Enum.any?(1..1000, fn _ -> blocked?("FOR NO KEY UPDATE") end),
             "the change did not wait"

      refute Task.yield(task, 0)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder)
      Task.await(task)
    end

    # Returns whether a query containing `statement` waits for a lock.
    defp blocked?(statement) do
      %{rows: [[count]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND strpos(query, $1) > 0",
          [statement]
        )

      count > 0
    end
  end
end
