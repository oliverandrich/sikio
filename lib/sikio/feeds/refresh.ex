# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Refresh do
  @moduledoc """
  Refreshes a source while at least one subscriber wants updates.

  The check is repeated here rather than trusted from the scheduler, because a feed can be paused
  or unsubscribed in the minutes a job spends in the queue. Failures are returned so Oban retries
  them; a source that is down for an hour is not a source that is gone.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 3, unique: [period: 300, keys: [:feed_id]]

  alias Sikio.Feeds
  alias Sikio.Library

  @impl true
  def perform(%Oban.Job{args: %{"feed_id" => id}}) do
    if Library.active_feed?(id) do
      # New entries go where each subscription sends them, in the same transaction.
      case Feeds.refresh(id, &Library.deliver/2) do
        {:ok, _feed} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
