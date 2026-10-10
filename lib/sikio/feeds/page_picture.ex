# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.PagePicture do
  @moduledoc """
  Takes Mediathek programmes' pictures from their broadcasters' pages.

  MediathekViewWeb names no picture. Storing new programmes enqueues one job for all of them, so
  no save or poll waits for a broadcaster. Refreshes run first, since this job has a lower
  priority. A page without a picture leaves the placeholder. An unreachable page fails the job,
  and Oban retries the programmes still without a picture, up to three attempts in all.
  The stored pictures are broadcast once.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 3, priority: 5

  import Ecto.Query

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Entry
  alias Sikio.Library.Events
  alias Sikio.Repo

  @impl true
  def perform(%Oban.Job{args: %{"feed_id" => feed_id, "entry_ids" => ids}}) do
    entries =
      Repo.all(
        from e in Entry,
          where: e.id in ^ids and is_nil(e.image_url) and not is_nil(e.page_url),
          select: {e.id, e.page_url}
      )

    # A few pages at a time, so no broadcaster sees a burst.
    answers =
      entries
      |> Task.async_stream(fn {id, page} -> {id, Discovery.page_picture(page)} end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    stored = for {id, {:ok, picture}} <- answers, do: store(id, picture)
    if Enum.sum(stored) > 0, do: Events.feed_updated(feed_id)

    if Enum.any?(answers, &match?({_id, {:error, :unavailable}}, &1)),
      do: {:error, :unavailable},
      else: :ok
  end

  defp store(id, picture) do
    {stored, _} =
      Repo.update_all(from(e in Entry, where: e.id == ^id and is_nil(e.image_url)),
        set: [image_url: picture]
      )

    stored
  end
end
