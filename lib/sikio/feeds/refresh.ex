# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Refresh do
  @moduledoc """
  Refreshes a feed if it has at least one unpaused subscription.

  The check repeats here instead of relying on the scheduler. A feed can be paused or unsubscribed
  while the job waits in the queue. Failures are returned so Oban retries them. A temporary
  outage does not mean the feed is gone.
  """
  # Unique while the job waits or runs, with no time limit. A full queue can hold a job longer
  # than the scheduler's five-minute interval, so a fixed period could admit duplicates.
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
      # `Library.deliver/2` routes new entries to subscriptions in the same transaction.
      case Feeds.refresh(id, &Library.deliver/2) do
        {:ok, _feed} -> :ok
        # The server's `Retry-After` is already in `next_check_at`, so Oban does not retry.
        {:error, :busy} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
