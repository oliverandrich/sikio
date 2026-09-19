defmodule Sikio.Feeds do
  @moduledoc """
  Persistence and refresh of shared feed content.

  A feed is stored once for everybody who subscribes to it, so nothing here is account-scoped and
  nothing here may carry progress. Imports are upserts, because the same episode arrives again on
  every poll and has to stay the same row.
  """
  import Ecto.Query

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Library.Events
  alias Sikio.Repo

  def store(preview) do
    Repo.transaction(fn ->
      attrs = Map.merge(preview, %{last_checked_at: DateTime.utc_now(), last_error: nil})

      case Repo.insert(Feed.changeset(%Feed{}, attrs),
             on_conflict:
               {:replace,
                [:title, :etag, :last_modified, :last_checked_at, :last_error, :updated_at]},
             conflict_target: [:url],
             returning: true
           ) do
        {:ok, feed} ->
          import_entries(feed.id, preview.entries)
          feed

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  def refresh(id) do
    case Repo.get(Feed, id) do
      nil ->
        {:error, :not_found}

      feed ->
        case refresh_feed(feed) do
          {:ok, refreshed} ->
            Events.feed_updated(feed.id)
            {:ok, refreshed}

          {:unchanged, refreshed} ->
            {:ok, refreshed}

          other ->
            other
        end
    end
  end

  defp refresh_feed(feed) do
    headers =
      [{"if-none-match", feed.etag}, {"if-modified-since", feed.last_modified}]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    case Discovery.fetch(feed.url, headers) do
      {:ok, preview} ->
        # Keep the original stable subscription URL even when its endpoint redirects.
        store(%{preview | url: feed.url})

      # Nothing changed, so nobody is told. Each notification costs every open library a reload.
      :not_modified ->
        feed
        |> Ecto.Changeset.change(last_checked_at: DateTime.utc_now(), last_error: nil)
        |> Repo.update()
        |> case do
          {:ok, feed} -> {:unchanged, feed}
          other -> other
        end

      {:error, reason} ->
        Repo.update_all(from(f in Feed, where: f.id == ^feed.id),
          set: [last_checked_at: DateTime.utc_now(), last_error: to_string(reason)]
        )

        {:error, reason}
    end
  end

  defp import_entries(feed_id, entries) do
    now = DateTime.utc_now()

    rows =
      entries
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.map(fn entry ->
        entry
        |> Map.take([:external_id, :title, :media_url, :video_id, :published_at])
        |> Map.merge(%{feed_id: feed_id, inserted_at: now, updated_at: now})
        |> Map.update(:published_at, nil, &microseconds/1)
      end)

    Repo.insert_all(Entry, rows,
      on_conflict: {:replace, [:title, :media_url, :video_id, :published_at, :updated_at]},
      conflict_target: [:feed_id, :external_id]
    )
  end

  # `insert_all` writes what it is given, without the schema's type casting, so a timestamp parsed
  # out of a feed has to match the column's precision before it gets there.
  defp microseconds(nil), do: nil
  defp microseconds(date), do: %{date | microsecond: {elem(date.microsecond, 0), 6}}
end
