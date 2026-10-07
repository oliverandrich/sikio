# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.DatabaseTest do
  @moduledoc """
  One build serves both databases, chosen with SIKIO_DATABASE when the application starts. The
  repository and the job queue follow that choice together, and either database holds the same
  rules.
  """
  use Sikio.DataCase, async: true

  alias Sikio.Accounts.User
  alias Sikio.Feeds.{Entry, Feed}
  alias Sikio.Repo

  test "the repository and the job queue serve the database the application started with" do
    {adapter, engine} =
      case Application.fetch_env!(:sikio, :database) do
        :sqlite -> {Ecto.Adapters.SQLite3, Oban.Engines.Lite}
        :postgres -> {Ecto.Adapters.Postgres, Oban.Engines.Basic}
      end

    assert Repo.__adapter__() == adapter

    assert Oban.config().engine == engine
  end

  # The repositories are started under Sikio.Repo's name and read its configuration. What is set
  # there wins over Ecto's own defaults, such as its pool of ten.
  test "the repository runs with the configuration set for Sikio.Repo" do
    configured = Application.fetch_env!(:sikio, Repo)[:pool_size]
    refute configured == 10
    assert Repo.config()[:pool_size] == configured
  end

  # The checks are in the database as well as in the code, because a row can arrive by a path the
  # code does not guard. Each database names the rule it refused.
  test "the database itself refuses what no row may hold" do
    now = DateTime.utc_now()

    feed = %{
      url: "https://example.org/#{unique()}",
      title: "F",
      inserted_at: now,
      updated_at: now
    }

    assert {1, _} = Repo.insert_all(Feed, [Map.put(feed, :kind, :peertube)])

    assert refused("valid_feed_kind", fn ->
             Repo.insert_all("feeds", [%{feed | url: feed.url <> "/rss"} |> Map.put(:kind, "rss")])
           end)

    user = Repo.insert!(%User{username: unique_username()})
    [feed] = Repo.all(from f in Feed, where: f.url == ^feed.url)
    entry = Repo.insert!(%Entry{feed_id: feed.id, external_id: "e", title: "E"})

    state = %{user_id: user.id, entry_id: entry.id, inserted_at: now, updated_at: now}

    for {rule, column, value} <- [
          {"valid_status", :status, "lost"},
          {"valid_position", :position, 31_536_001.0},
          {"valid_duration", :duration, 0.0}
        ] do
      assert refused(rule, fn ->
               Repo.insert_all("playback_states", [Map.put(state, column, value)])
             end)
    end
  end

  # SQLite as dj-lite sets it up for Django: a write-ahead log, a writer that waits rather than
  # fails, and transactions that take the write lock when they begin.
  if Application.compile_env!(:sikio, :database) == :sqlite do
    test "a SQLite connection carries the production presets" do
      pragma = fn name -> Repo.query!("PRAGMA #{name}").rows end

      assert pragma.("journal_mode") == [["wal"]]
      assert pragma.("synchronous") == [[1]]
      assert pragma.("temp_store") == [[2]]
      assert pragma.("mmap_size") == [[134_217_728]]
      assert pragma.("journal_size_limit") == [[27_103_364]]
      assert pragma.("cache_size") == [[2000]]
      assert pragma.("foreign_keys") == [[1]]
      # Neither has a pragma to read back: exqlite waits in a busy handler of its own.
      assert Repo.config()[:busy_timeout] == 5000
      assert Repo.config()[:default_transaction_mode] == :immediate
    end
  end

  defp refused(rule, insert) do
    insert.()
    false
  rescue
    error -> Exception.message(error) =~ rule
  end
end
