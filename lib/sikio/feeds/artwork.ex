# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Artwork do
  @moduledoc """
  Asks Apple's directory for a podcast's missing artwork; see `Sikio.Feeds.artwork/1`.

  Storing or refreshing a due feed enqueues this job, so no poll waits for the directory.
  Found artwork is broadcast, so sidebar and lists show it at once.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 1, unique: [keys: [:feed_id]]

  alias Sikio.Feeds
  alias Sikio.Feeds.Feed
  alias Sikio.Library.Events
  alias Sikio.Repo

  @impl true
  def perform(%Oban.Job{args: %{"feed_id" => id}}) do
    with %Feed{} = feed <- Repo.get(Feed, id),
         %Feed{icon_url: icon} when icon != feed.icon_url <- Feeds.artwork(feed),
         do: Events.feed_updated(id)

    :ok
  end
end
