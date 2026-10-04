# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.QueueMigrationTest do
  @moduledoc """
  The migration that puts what is under way into the queue, where playing an item puts it now.

  Without it, what was in progress before the inbox would stand in neither the inbox nor the
  queue. The last played comes first.
  """
  use Sikio.MigrationCase

  alias Sikio.Accounts.User
  alias Sikio.Feeds.{Entry, Feed}

  @before 20_261_006_090_000
  @version 20_261_006_100_000

  test "what is under way is queued, the last played first", %{repo: repo} do
    migrate(repo, :up, @before)

    user = Repo.insert!(%User{username: "ada"})
    other = Repo.insert!(%User{username: "grace"})
    feed = Repo.insert!(%Feed{url: "https://example.org/rss", kind: :podcast, title: "F"})

    rows = [
      {user, "played an hour ago", "in_progress", 60},
      {user, "played just now", "in_progress", 1},
      {user, "played yesterday", "in_progress", 1440},
      {user, "heard", "heard", 5},
      {user, "untouched", "new", 5},
      {other, "somebody else's", "in_progress", 30}
    ]

    for {account, title, status, minutes_ago} <- rows do
      entry =
        Repo.insert!(%Entry{
          feed_id: feed.id,
          external_id: "#{account.id}-#{title}",
          title: title
        })

      at = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

      Repo.insert_all("playback_states", [
        %{
          user_id: account.id,
          entry_id: entry.id,
          status: status,
          inserted_at: at,
          updated_at: at
        }
      ])
    end

    migrate(repo, :up, @version)

    queue = fn account ->
      Repo.all(
        from p in "playback_states",
          join: e in "entries",
          on: e.id == p.entry_id,
          where: p.user_id == ^account.id and not is_nil(p.queue_rank),
          order_by: [asc: p.queue_rank],
          select: e.title
      )
    end

    assert queue.(user) == ["played just now", "played an hour ago", "played yesterday"]
    assert queue.(other) == ["somebody else's"]
  end
end
