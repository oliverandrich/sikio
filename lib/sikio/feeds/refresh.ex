# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Refresh do
  @moduledoc """
  Refreshes a source while at least one subscriber wants updates.

  The check is repeated here rather than trusted from the scheduler, because a feed can be paused
  or unsubscribed in the minutes a job spends in the queue. Failures are returned so Oban retries
  them; a source that is down for an hour is not a source that is gone.
  """
  # Unique while it waits or runs, however long a full queue keeps it, rather than for a period
  # the scheduler's own five minutes could outlast.
  use Oban.Worker,
    queue: :feeds,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:feed_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Sikio.Feeds
  alias Sikio.Library

  @impl true
  def perform(%Oban.Job{args: %{"feed_id" => id}}) do
    if Library.active_feed?(id) do
      # New entries go where each subscription sends them, in the same transaction.
      case Feeds.refresh(id, &Library.deliver/2) do
        {:ok, _feed} -> :ok
        # The server named when to come back, and the feed's next check says so already.
        {:error, :busy} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
