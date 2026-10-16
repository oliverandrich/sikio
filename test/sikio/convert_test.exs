# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ConvertTest do
  @moduledoc false
  use Sikio.ConvertCase

  alias Sikio.Accounts.User
  alias Sikio.Convert
  alias Sikio.DataCase
  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo
  alias Sikio.Tags

  test "a library survives PostgreSQL to SQLite and back unchanged" do
    source = postgres!()
    seed(source)
    lite = sqlite!()
    target = postgres!()

    assert :ok = Convert.copy(source, lite)
    assert :ok = Convert.copy(lite, target)

    copied = snapshot(source)
    assert snapshot(target) == copied

    assert Enum.all?(
             ~w(ithibati_keys ithibati_sessions ithibati_recovery_codes),
             &(copied[&1] != [])
           )

    # SQLite's triggers indexed the copied entries for the library search.
    assert %{rows: [[1]]} =
             query!(lite, "SELECT count(*) FROM entries_search WHERE search_text MATCH 'two'")

    assert %{rows: []} = query!(lite, "PRAGMA foreign_key_check")

    # The target's sequences continue after the copied ids.
    {_module, repo} = target
    Repo.put_dynamic_repo(repo)

    assert %User{} =
             Repo.insert!(User.changeset(%User{}, %{username: DataCase.unique_username()}))
  end

  describe "a refused conversion" do
    setup do
      source = postgres!()
      seed(source)
      %{source: source, lite: sqlite!()}
    end

    test "leaves a target alone that already holds rows", c do
      assert :ok = Convert.copy(c.source, c.lite)
      assert {:error, {:not_empty, _table}} = Convert.copy(c.source, c.lite)
    end

    test "needs both databases at the same migration versions", c do
      query!(
        c.lite,
        "DELETE FROM schema_migrations WHERE version = (SELECT max(version) FROM schema_migrations)"
      )

      assert {:error, :migrations_differ} = Convert.copy(c.source, c.lite)
    end

    test "names a table only one side has", c do
      query!(c.lite, "CREATE TABLE stray (id INTEGER)")
      assert {:error, {:tables_differ, ["stray"]}} = Convert.copy(c.source, c.lite)
    end

    test "names a column type it cannot convert", c do
      query!(c.source, "ALTER TABLE users ADD COLUMN spot point")

      assert {:error, {:unknown_type, "users", "spot", "point"}} =
               Convert.copy(c.source, c.lite)
    end
  end

  # A library with a passkey, a session and a recovery code, so every column type holds a value.
  defp seed({_module, repo}) do
    Repo.put_dynamic_repo(repo)
    user = Repo.insert!(User.changeset(%User{}, %{username: DataCase.unique_username()}))
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), FeedFixtures.feed_url())
    {:ok, sub} = Library.subscribe(user, preview)
    [entry] = Library.entries(user)
    {:ok, _tags} = Tags.set(user, sub.id, ["Evening"])
    {:ok, _favourite} = Library.favourite(user, entry.id, true)
    {:ok, playback} = Playback.start(user, entry.id)
    sample = %{"sequence" => 1, "position" => 41.5, "duration" => 100, "ended" => false}
    {:ok, _state} = Playback.save(user, entry.id, playback.session_id, sample)

    query!(
      {Repo.Postgres, repo},
      "UPDATE entries SET chapters = $1 WHERE id = $2",
      [[%{"start" => 0, "title" => "Intro"}], entry.id]
    )

    now = DateTime.utc_now()
    Repo.insert!(%Ithibati.UserKey{user_id: user.id, key_id: <<1, 2, 3>>, public_key: <<4, 5>>})
    Repo.insert!(%Ithibati.Session{user_id: user.id, token_hash: :crypto.strong_rand_bytes(32)})

    Repo.insert!(%Ithibati.RecoveryCode{
      user_id: user.id,
      code_hash: :crypto.strong_rand_bytes(32),
      used_at: now
    })
  end

  # Every copied table's rows, as the database driver returns them.
  defp snapshot(target) do
    %{rows: tables} =
      query!(target, """
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
      """)

    for [table] <- tables, not Convert.skipped?(table), into: %{} do
      %{rows: rows} = query!(target, ~s|SELECT * FROM "#{table}"|)
      {table, Enum.sort(rows)}
    end
  end
end
