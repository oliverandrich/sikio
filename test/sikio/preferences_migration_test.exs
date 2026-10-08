# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PreferencesMigrationTest do
  @moduledoc """
  Tests the migration that moves `playback_preferences` into a new `preferences` table.

  An existing Play on setting stays. The start page defaults to the queue, and the language to
  the browser's. A deleted tag clears the start page's tag. A rollback keeps Play on.
  """
  use Sikio.MigrationCase

  alias Sikio.Accounts.User

  @before 20_261_007_120_000
  @version 20_261_008_100_000

  test "an account keeps its Play on, and a deleted start tag falls back", %{repo: repo} do
    migrate(repo, :up, @before)

    ada = Repo.insert!(%User{username: "ada"})
    now = DateTime.utc_now()

    Repo.insert_all("playback_preferences", [
      %{user_id: ada.id, play_on: false, inserted_at: now, updated_at: now}
    ])

    migrate(repo, :up, @version)

    assert Repo.all(
             from p in "preferences",
               select: {p.user_id, p.play_on == true, p.start_view, p.start_tag_id, p.locale}
           ) == [{ada.id, false, "queue", nil, nil}]

    # An upgraded PostgreSQL database names its index like a fresh one.
    if Repo.postgres?() do
      assert Repo.all(
               from i in "pg_indexes", where: i.tablename == "preferences", select: i.indexname
             )
             |> Enum.sort() == ["preferences_pkey", "preferences_user_id_index"]
    end

    tag = %{user_id: ada.id, name: "Tech", key: "tech", inserted_at: now, updated_at: now}
    {1, [%{id: tag_id}]} = Repo.insert_all("tags", [tag], returning: [:id])
    Repo.update_all("preferences", set: [start_tag_id: tag_id])
    Repo.delete_all(from t in "tags", where: t.id == ^tag_id)

    assert Repo.all(from p in "preferences", select: p.start_tag_id) == [nil]

    # Rolling back restores the old table with Play on.
    migrate(repo, :down, @before)

    assert Repo.all(from p in "playback_preferences", select: {p.user_id, p.play_on == true}) ==
             [{ada.id, false}]
  end
end
