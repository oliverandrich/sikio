# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds do
  @moduledoc """
  Persistence and refresh of shared feed content.

  A feed is stored once for everybody who subscribes to it, so nothing here is account-scoped and
  nothing here may carry progress. Imports are upserts, because the same episode arrives again on
  every poll and has to stay the same row.
  """
  import Ecto.Query

  alias Sikio.Chapters
  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Library.Events
  alias Sikio.Repo

  @feed_fields [:title, :etag, :last_modified, :last_checked_at, :last_error, :updated_at]

  # Everything the source just said replaces what was stored, except the picture. A YouTube
  # refresh reads the Atom feed alone, which names no artwork, and an empty value there is the
  # absence of a statement rather than a statement that the channel has no picture. One row is
  # written here, so leaving the column out of the list says exactly that.
  defp replaced_feed_fields(%{icon_url: url}) when is_binary(url), do: [:icon_url | @feed_fields]
  defp replaced_feed_fields(_attrs), do: @feed_fields

  def store(preview) do
    with {:ok, {feed, _written}} <- store_entries(preview), do: {:ok, feed}
  end

  # The feed and how many of its entries were inserted or actually changed.
  defp store_entries(preview) do
    Repo.transaction(fn ->
      attrs = Map.merge(preview, %{last_checked_at: DateTime.utc_now(), last_error: nil})

      case Repo.insert(Feed.changeset(%Feed{}, attrs),
             on_conflict: {:replace, replaced_feed_fields(attrs)},
             conflict_target: [:url],
             returning: true
           ) do
        {:ok, feed} ->
          {written, _} = import_entries(feed.id, preview.entries)
          {feed, written}

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  @doc """
  An item's chapters as its feed names them: listed in the item, or in the file it links.

  The file is fetched once, the first time somebody opens the item, through the guarded client
  and with a small limit; what it holds is stored on the shared entry, so nobody fetches it again.
  A file that cannot be reached is tried again next time. One that holds no chapters is stored
  as such. Answers nil when the feed names no chapters at all.
  """
  def chapters(%Entry{chapters: chapters}) when is_list(chapters), do: {:ok, chapters}
  def chapters(%Entry{chapters_url: nil}), do: {:ok, nil}

  def chapters(%Entry{id: id, chapters_url: url}) do
    case HTTP.get(url, max_bytes: 256_000) do
      {:ok, %{status: 200, body: body}} ->
        chapters = Chapters.from_json(body)
        Repo.update_all(from(e in Entry, where: e.id == ^id), set: [chapters: chapters])
        {:ok, chapters}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh(id) do
    case Repo.get(Feed, id) do
      nil ->
        {:error, :not_found}

      feed ->
        result = refresh_feed(feed)
        if news?(result, feed), do: Events.feed_updated(feed.id)

        case result do
          {:unchanged, refreshed} -> {:ok, refreshed}
          other -> other
        end
    end
  end

  # Subscribers hear of new content, and of a source that starts failing or recovers: the sidebar
  # marks a failing one. Failing again, or answering the same, is nothing new.
  defp news?({:ok, _refreshed}, _feed), do: true
  defp news?({:unchanged, _refreshed}, feed), do: feed.last_error != nil
  defp news?({:error, _reason}, feed), do: feed.last_error == nil

  defp refresh_feed(feed) do
    headers =
      [{"if-none-match", feed.etag}, {"if-modified-since", feed.last_modified}]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    case Discovery.fetch(feed.url, headers) do
      # Keep the original stable subscription URL even when its endpoint redirects.
      {:ok, preview} ->
        %{preview | url: feed.url} |> store_entries() |> compared_with(feed)

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

  # A document that repeats what is stored notifies nobody, like a 304. What a reader sees of the
  # source itself, its name and picture, counts as much as its entries.
  defp compared_with({:ok, {stored, 0}}, feed)
       when stored.title == feed.title and stored.icon_url == feed.icon_url,
       do: {:unchanged, stored}

  defp compared_with({:ok, {stored, _written}}, _feed), do: {:ok, stored}
  defp compared_with(other, _feed), do: other

  @replaced_entry_fields [:title, :media_url, :video_id, :embed_url, :published_at]
  @kept_entry_fields [
    :image_url,
    :duration,
    :description,
    :description_format,
    :excerpt,
    :page_url,
    :chapters,
    :chapters_url
  ]

  defp import_entries(feed_id, entries) do
    now = DateTime.utc_now()

    rows =
      entries
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.map(fn entry ->
        entry
        |> Map.take([:external_id | @replaced_entry_fields ++ @kept_entry_fields])
        |> Map.merge(%{feed_id: feed_id, inserted_at: now, updated_at: now})
        |> Map.update(:published_at, nil, &microseconds/1)
      end)

    Repo.insert_all(Entry, rows,
      on_conflict: keep_content(),
      conflict_target: [:feed_id, :external_id]
    )
  end

  # What identifies and locates an episode is replaced outright, because a feed that moves its
  # audio has moved it. Artwork, runtime, notes, the page and chapters are not: a poll that leaves them out is a poll
  # that said nothing about them, and a show that trims one document should not strip every
  # episode it ever published. The same rule the feed's own picture follows.
  #
  # A row whose values would not change is not written at all. Rewriting it costs a new row
  # version, write ahead log and a dead tuple on every poll of a source without cache
  # validators. The whole row is compared at once, null-safe, against exactly what the update
  # would set. The guard and the update name their columns separately; the tests change each
  # column on its own and expect a write, so a column left out of the guard fails one of them.
  defp keep_content do
    from(e in Entry,
      where:
        fragment(
          """
          (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) IS DISTINCT FROM
          (EXCLUDED.title, EXCLUDED.media_url, EXCLUDED.video_id, EXCLUDED.embed_url,
           EXCLUDED.published_at, COALESCE(EXCLUDED.image_url, ?), COALESCE(EXCLUDED.duration, ?),
           COALESCE(EXCLUDED.description, ?), COALESCE(EXCLUDED.description_format, ?),
           COALESCE(EXCLUDED.excerpt, ?), COALESCE(EXCLUDED.page_url, ?),
           COALESCE(EXCLUDED.chapters, ?), COALESCE(EXCLUDED.chapters_url, ?))
          """,
          e.title,
          e.media_url,
          e.video_id,
          e.embed_url,
          e.published_at,
          e.image_url,
          e.duration,
          e.description,
          e.description_format,
          e.excerpt,
          e.page_url,
          e.chapters,
          e.chapters_url,
          e.image_url,
          e.duration,
          e.description,
          e.description_format,
          e.excerpt,
          e.page_url,
          e.chapters,
          e.chapters_url
        ),
      update: [
        set: [
          title: fragment("EXCLUDED.title"),
          media_url: fragment("EXCLUDED.media_url"),
          video_id: fragment("EXCLUDED.video_id"),
          embed_url: fragment("EXCLUDED.embed_url"),
          published_at: fragment("EXCLUDED.published_at"),
          image_url: fragment("COALESCE(EXCLUDED.image_url, ?)", e.image_url),
          duration: fragment("COALESCE(EXCLUDED.duration, ?)", e.duration),
          description: fragment("COALESCE(EXCLUDED.description, ?)", e.description),
          description_format:
            fragment("COALESCE(EXCLUDED.description_format, ?)", e.description_format),
          excerpt: fragment("COALESCE(EXCLUDED.excerpt, ?)", e.excerpt),
          page_url: fragment("COALESCE(EXCLUDED.page_url, ?)", e.page_url),
          # Chapters fetched from a file belong to it: a feed linking another file has them
          # fetched again.
          chapters:
            fragment(
              "CASE WHEN EXCLUDED.chapters IS NULL AND EXCLUDED.chapters_url IS DISTINCT FROM ? THEN NULL ELSE COALESCE(EXCLUDED.chapters, ?) END",
              e.chapters_url,
              e.chapters
            ),
          chapters_url: fragment("COALESCE(EXCLUDED.chapters_url, ?)", e.chapters_url),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # `insert_all` writes what it is given, without the schema's type casting, so a timestamp parsed
  # out of a feed has to match the column's precision before it gets there.
  defp microseconds(nil), do: nil
  defp microseconds(date), do: %{date | microsecond: {elem(date.microsecond, 0), 6}}
end
