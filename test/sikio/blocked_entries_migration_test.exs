# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.BlockedEntriesMigrationTest do
  @moduledoc """
  Tests the migration that adds blocked entries: one block per feed and external id, gone with
  its feed, and gone again on rollback.
  """
  use Sikio.MigrationCase

  @before 20_261_018_100_000
  @version 20_261_018_110_000

  test "a block is unique per feed and goes with its feed and the rollback", %{repo: repo} do
    migrate(repo, :up, @version)
    now = DateTime.utc_now()

    {1, [%{id: feed_id}]} =
      Repo.insert_all(
        "feeds",
        [
          %{
            url: "https://example.org/rss",
            title: "Feed",
            kind: "podcast",
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    block = %{feed_id: feed_id, external_id: "episode-1", inserted_at: now}
    Repo.insert_all("blocked_entries", [block])
    assert_raise database_error(), fn -> Repo.insert_all("blocked_entries", [block]) end

    Repo.delete_all(from f in "feeds", where: f.id == ^feed_id)
    assert Repo.all(from b in "blocked_entries", select: b.id) == []

    migrate(repo, :down, @before)
    assert_raise database_error(), fn -> Repo.all(from b in "blocked_entries", select: b.id) end
  end
end
