# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.KeyMediathekEntriesByPage do
  use Ecto.Migration

  import Ecto.Query

  @moduledoc """
  Keys stored Mediathek programmes by their broadcaster's page and title, as the parser now does.

  MediathekViewWeb lists a geo-blocked copy beside the open one and can change its ids, so a
  series held copies of one programme. The copies of one title on one page merge into one entry:
  the open copy, else the oldest. Each account keeps its furthest playback state, with a queue
  place any copy held, and its saved entry. A programme without a page keeps its id.

  Programmes without a picture then ask their broadcaster's page, in one job per series.
  The merge cannot be undone, so a rollback changes nothing.
  """

  # Furthest first. A state further along wins a merge.
  @progress %{"heard" => 3, "in_progress" => 2, "new" => 1, "archived" => 0}

  def up do
    mediathek = from(f in "feeds", where: f.kind == "mediathek", select: f.id)

    programmes =
      repo().all(
        from(e in "entries",
          where: e.feed_id in subquery(mediathek) and not is_nil(e.page_url),
          select: %{
            id: e.id,
            feed_id: e.feed_id,
            page: e.page_url,
            title: e.title,
            media: e.media_url
          }
        )
      )

    for {_programme, [_, _ | _] = copies} <-
          Enum.group_by(programmes, &{&1.feed_id, &1.page, &1.title}) do
      [kept | merged] = Enum.sort_by(copies, &{geo_blocked?(&1.media), &1.id})
      Enum.each(merged, &merge(&1.id, kept.id))
    end

    repo().update_all(
      from(e in "entries",
        where: e.feed_id in subquery(mediathek) and not is_nil(e.page_url),
        update: [set: [external_id: fragment("? || ' ' || ?", e.page_url, e.title)]]
      ),
      []
    )

    ask_for_pictures()
  end

  def down, do: :ok

  defp merge(from_id, into_id) do
    states =
      repo().all(
        from(p in "playback_states",
          where: p.entry_id in ^[from_id, into_id],
          select: %{
            id: p.id,
            user_id: p.user_id,
            status: p.status,
            position: p.position,
            queue_rank: p.queue_rank
          }
        )
      )

    for {_user_id, rows} <- Enum.group_by(states, & &1.user_id) do
      [furthest | others] =
        Enum.sort_by(rows, &{@progress[&1.status], seconds(&1.position)}, :desc)

      repo().delete_all(from(p in "playback_states", where: p.id in ^Enum.map(others, & &1.id)))

      rank =
        rows |> Enum.map(& &1.queue_rank) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)

      repo().update_all(from(p in "playback_states", where: p.id == ^furthest.id),
        set: [entry_id: into_id, queue_rank: rank]
      )
    end

    saved_into =
      from(s in "saved_entries", where: s.entry_id == ^into_id, select: s.user_id)

    repo().delete_all(
      from(s in "saved_entries",
        where: s.entry_id == ^from_id and s.user_id in subquery(saved_into)
      )
    )

    repo().update_all(from(s in "saved_entries", where: s.entry_id == ^from_id),
      set: [entry_id: into_id]
    )

    repo().delete_all(from(e in "entries", where: e.id == ^from_id))
  end

  # The parser's rule at the time of this migration, kept here so the migration does not change.
  defp geo_blocked?(url) when is_binary(url), do: Regex.match?(~r{/geo/|/de/|cms-austria}, url)
  defp geo_blocked?(_url), do: false

  # PostgreSQL returns a numeric column as a Decimal.
  defp seconds(%Decimal{} = position), do: Decimal.to_float(position)
  defp seconds(position), do: position

  defp ask_for_pictures do
    waiting =
      repo().all(
        from(e in "entries",
          join: f in "feeds",
          on: f.id == e.feed_id,
          where: f.kind == "mediathek" and not is_nil(e.page_url) and is_nil(e.image_url),
          select: {e.feed_id, e.id}
        )
      )

    for {feed_id, ids} <- Enum.group_by(waiting, &elem(&1, 0), &elem(&1, 1)) do
      %{feed_id: feed_id, entry_ids: Enum.sort(ids)}
      |> Oban.Job.new(
        worker: "Sikio.Feeds.PagePicture",
        queue: :feeds,
        max_attempts: 3,
        priority: 5
      )
      |> repo().insert!()
    end
  end
end
