# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PlaybackMigrationTest do
  @moduledoc """
  The migration that splits what was finished into heard and archived, and adds the queue.

  It runs on a database of its own, made for the test and dropped after it: a migration cannot be
  watched inside the sandbox, which starts with every migration already run. What was completed
  becomes heard when its place had reached 90 % of its length, and archived otherwise.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Feeds.{Entry, Feed}
  alias Sikio.Repo

  @before 20_261_005_090_000
  @version 20_261_006_090_000

  setup do
    name =
      case Application.fetch_env!(:sikio, :database) do
        :sqlite -> Path.join(System.tmp_dir!(), "sikio_migration_#{unique()}.db")
        :postgres -> "sikio_migration_#{unique()}"
      end

    config =
      Keyword.merge(Repo.config(),
        name: nil,
        database: name,
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    # Each test loads the migration files again, which redefines their modules on purpose.
    conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, conflicts) end)

    :ok = Repo.__adapter__().storage_up(config)
    {:ok, repo} = Repo.start_link(config)
    previous = Repo.put_dynamic_repo(repo)

    # The repo ends with the test process it is linked to; what is left is the database.
    on_exit(fn -> Repo.__adapter__().storage_down(config) end)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{repo: repo}
  end

  test "what was finished becomes heard or archived by how far it was played", %{repo: repo} do
    migrate(repo, :up, @before)

    user = Repo.insert!(%User{username: "ada"})
    feed = Repo.insert!(%Feed{url: "https://example.org/rss", kind: :podcast, title: "F"})

    rows = [
      {"near the end", :completed, 95.0, 100.0, nil},
      {"half way", :completed, 50.0, 100.0, nil},
      {"length from the feed", :completed, 95.0, nil, 100},
      {"no length at all", :completed, 95.0, nil, nil},
      {"under way", :in_progress, 30.0, 100.0, nil},
      {"untouched", :new, 0.0, nil, nil}
    ]

    for {title, status, position, duration, length} <- rows do
      entry =
        Repo.insert!(%Entry{feed_id: feed.id, external_id: title, title: title, duration: length})

      now = DateTime.utc_now()

      Repo.insert_all("playback_states", [
        %{
          user_id: user.id,
          entry_id: entry.id,
          status: Atom.to_string(status),
          position: position,
          duration: duration,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    migrate(repo, :up, @version)

    assert statuses() == %{
             "near the end" => "heard",
             "half way" => "archived",
             "length from the feed" => "heard",
             "no length at all" => "archived",
             "under way" => "in_progress",
             "untouched" => "new"
           }

    # The queue holds a rank, and the database refuses a status it no longer knows.
    Repo.update_all(from(p in "playback_states"), set: [queue_rank: 1.0])

    assert_raise error_module(), fn ->
      Repo.update_all(from(p in "playback_states"), set: [status: "completed"])
    end
  end

  test "rolled back, heard and archived are finished again and the queue is gone", %{repo: repo} do
    migrate(repo, :up, @version)

    user = Repo.insert!(%User{username: "ada"})
    feed = Repo.insert!(%Feed{url: "https://example.org/rss", kind: :podcast, title: "F"})

    for {title, status} <- [{"heard", "heard"}, {"archived", "archived"}, {"new", "new"}] do
      entry = Repo.insert!(%Entry{feed_id: feed.id, external_id: title, title: title})
      now = DateTime.utc_now()

      Repo.insert_all("playback_states", [
        %{
          user_id: user.id,
          entry_id: entry.id,
          status: status,
          queue_rank: 1.0,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    migrate(repo, :down, @before)

    assert statuses() == %{"heard" => "completed", "archived" => "completed", "new" => "new"}
    assert_raise_on_queue_rank()
  end

  defp migrate(repo, direction, version) do
    path = Ecto.Migrator.migrations_path(Repo)
    opts = [dynamic_repo: repo, log: false, log_migrations_sql: false]

    case direction do
      :up -> Ecto.Migrator.run(Repo, path, :up, [to: version] ++ opts)
      :down -> Ecto.Migrator.run(Repo, path, :down, [to: version + 1] ++ opts)
    end
  end

  defp statuses do
    Repo.all(
      from p in "playback_states",
        join: e in "entries",
        on: e.id == p.entry_id,
        select: {e.title, p.status}
    )
    |> Map.new()
  end

  defp assert_raise_on_queue_rank do
    assert_raise error_module(), fn ->
      Repo.all(from p in "playback_states", select: p.queue_rank)
    end
  end

  defp error_module do
    case Application.fetch_env!(:sikio, :database) do
      :sqlite -> Exqlite.Error
      :postgres -> Postgrex.Error
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
