# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Refresh do
  @moduledoc """
  Refreshes a feed if it has at least one unpaused subscription.

  The check repeats here instead of relying on the scheduler. A feed can be paused or unsubscribed
  while the job waits in the queue. Failures are returned so Oban retries them. A temporary
  outage does not mean the feed is gone.

  Every attempt ends with `{:feed_checked, feed_id}` on the feed's topic, whatever its result.
  Only a page waiting for a refresh it queued follows that topic.
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

  @doc """
  Queues a refresh to run now.

  A queued job for the feed waiting for its time or a retry backoff moves to now instead.
  """
  def queue_now(feed_id) do
    # Oban replaces only fields set on the new job, so `scheduled_at` is explicit.
    %{feed_id: feed_id}
    |> new(
      scheduled_at: DateTime.utc_now(),
      replace: [scheduled: [:scheduled_at], retryable: [:scheduled_at]]
    )
    |> Oban.insert!()
  end

  @doc "Subscribes the caller to the feed's refresh results. Feed ids are not account-scoped."
  def subscribe(feed_id), do: Phoenix.PubSub.subscribe(Sikio.PubSub, topic(feed_id))

  def unsubscribe(feed_id), do: Phoenix.PubSub.unsubscribe(Sikio.PubSub, topic(feed_id))

  @impl true
  # A waiting page also needs the report after a skip or a raise.
  def perform(%Oban.Job{args: %{"feed_id" => id}}) do
    attempt(id)
  after
    Phoenix.PubSub.broadcast(Sikio.PubSub, topic(id), {:feed_checked, id})
  end

  defp attempt(id) do
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

  defp topic(feed_id), do: "feed_checks:#{feed_id}"
end
