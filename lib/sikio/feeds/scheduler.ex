# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Scheduler do
  @moduledoc """
  Enqueues one refresh job per due feed, regardless of subscriber count.

  A feed is stored once, so it is polled once. Ten subscribers to one show still cause one request
  per interval. The scheduler runs every five minutes. Each feed has its own due time, so requests
  spread over the interval.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 1, unique: [period: 60]

  alias Sikio.Feeds.Refresh
  alias Sikio.Library

  @impl true
  def perform(_job) do
    Library.due_feed_ids()
    |> Enum.each(fn id -> %{feed_id: id} |> Refresh.new() |> Oban.insert!() end)
  end
end
