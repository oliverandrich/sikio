defmodule Sikio.Feeds.Scheduler do
  @moduledoc """
  Schedules one refresh per active feed, regardless of subscriber count.

  A feed is stored once, so it is polled once. Ten people subscribed to the same show is still one
  request to that show's server every quarter of an hour.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 1, unique: [period: 60]

  alias Sikio.Feeds.Refresh
  alias Sikio.Library

  @impl true
  def perform(_job) do
    Library.active_feed_ids()
    |> Enum.each(fn id -> %{feed_id: id} |> Refresh.new() |> Oban.insert!() end)
  end
end
