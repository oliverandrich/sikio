# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds do
  @moduledoc """
  Persistence and refresh of shared feed content.

  Feeds and entries are shared between accounts. Nothing here is account-scoped or stores
  playback progress. Imports are upserts, because every poll returns known episodes again.
  """
  import Ecto.Query

  require Logger

  alias Sikio.Chapters
  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Hub
  alias Sikio.Feeds.Schedule
  alias Sikio.Feeds.SearchText
  alias Sikio.Library.Events
  alias Sikio.Repo

  @feed_fields [:title, :etag, :last_modified, :last_checked_at, :last_error, :updated_at]

  # The upsert replaces every listed column. `icon_url` and `page_url` are listed only if present.
  # A missing value keeps the stored one. YouTube's Atom feed has no artwork.
  # A podcast may omit its link from a single response.
  defp replaced_feed_fields(attrs),
    do: Enum.filter([:icon_url, :page_url], &is_binary(attrs[&1])) ++ @feed_fields

  @doc "Base poll interval in minutes. Defaults to 60; `FEED_POLL_MINUTES` overrides it."
  def poll_minutes, do: Application.get_env(:sikio, :feed_poll_minutes, 60)

  @doc """
  Upserts a feed and its entries in one transaction.

  `on_new` receives the feed id and the ids of new entries, inside the same transaction.
  It is not called when no entry is new. The library passes a callback that delivers to
  subscriptions.
  """
  def store(preview, on_new \\ &ignore/2) do
    with {:ok, {feed, _written}} <- store_entries(preview, on_new), do: {:ok, feed}
  end

  defp ignore(_feed_id, _entry_ids), do: :ok

  defp announce(_on_new, _feed_id, []), do: :ok
  defp announce(on_new, feed_id, entry_ids), do: on_new.(feed_id, entry_ids)

  # Sets `next_check_at` from the age of the newest stored entry.
  defp schedule_next(feed_id, now, wait) do
    next = next_check(feed_id, now, newest(feed_id), wait)
    Repo.update_all(from(f in Feed, where: f.id == ^feed_id), set: [next_check_at: next])
    next
  end

  # A feed whose hub announces new entries polls once a day, as a safety net. While an announced
  # video is missing, it polls at the base interval regardless of the feed's age.
  defp next_check(feed_id, now, newest, wait) do
    {base, newest} =
      case Hub.pace(feed_id) do
        :live -> {Schedule.day_minutes(), newest}
        :awaiting -> {poll_minutes(), nil}
        :polling -> {poll_minutes(), newest}
      end

    Schedule.spread(now, Schedule.next_check(now, newest, base, wait))
  end

  # A failed check retries at the base interval, whatever the hub announces.
  defp retry_check(now, wait),
    do: Schedule.spread(now, Schedule.next_check(now, nil, poll_minutes(), wait))

  defp newest(feed_id),
    do: Repo.one(from e in Entry, where: e.feed_id == ^feed_id, select: max(e.published_at))

  # Returns the feed and the number of entries inserted or changed.
  defp store_entries(preview, on_new, wait \\ nil) do
    Repo.transaction(fn ->
      attrs = Map.merge(preview, %{last_checked_at: DateTime.utc_now(), last_error: nil})

      case Repo.insert(Feed.changeset(%Feed{}, attrs),
             on_conflict: {:replace, replaced_feed_fields(attrs)},
             conflict_target: [:url],
             returning: true
           ) do
        {:ok, feed} ->
          {written, new} = import_entries(feed.id, preview.entries)
          announce(on_new, feed.id, new)
          {%{feed | next_check_at: schedule_next(feed.id, attrs.last_checked_at, wait)}, written}

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  @doc """
  Returns an entry's chapters, embedded in the item or loaded from its chapters file.

  The file is fetched on the first call through `Sikio.Feeds.HTTP`, limited to 256 kB.
  The result is cached on the shared entry, so later calls skip the fetch.
  A failed fetch is not cached and is retried on the next call.
  A file without chapters is cached as an empty list.
  Returns `{:ok, nil}` when the entry has neither chapters nor a chapters file.
  """
  def chapters(%Entry{chapters: chapters}) when is_list(chapters), do: {:ok, chapters}
  def chapters(%Entry{chapters_url: nil}), do: {:ok, nil}

  def chapters(%Entry{id: id, chapters_url: url}) do
    case HTTP.get(url, max_bytes: 256_000) do
      {:ok, %{status: 200, body: body}} ->
        chapters = Chapters.from_json(body)

        # A concurrent refresh may have changed `chapters_url`. The update checks the fetched URL.
        Repo.update_all(from(e in Entry, where: e.id == ^id and e.chapters_url == ^url),
          set: [chapters: chapters]
        )

        {:ok, chapters}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the media a PeerTube instance names now for the video of an embed URL.

  A PeerTube feed names no HLS playlist, only HLS fragments a browser cannot play as files.
  The instance's API names the playlist and the audio-only file as `media_url` and `audio_url`.
  Nothing is stored, because the instance may move or re-transcode a video.
  """
  def media(embed_url), do: Discovery.peertube_files(embed_url)

  @doc """
  Fetches a feed again. `on_new` receives new entries as in `store/2`.

  Returns `{:error, :busy}` when a 429 or 503 response carried a valid `Retry-After`.
  The caller then does not retry before the feed's next check.
  Returns `{:error, :not_found}` for an unknown id.
  """
  def refresh(id, on_new \\ &ignore/2) do
    case Repo.get(Feed, id) do
      nil ->
        {:error, :not_found}

      feed ->
        result = refresh_feed(feed, on_new)
        if news?(result, feed), do: Events.feed_updated(feed.id)

        case result do
          {:unchanged, refreshed} -> {:ok, refreshed}
          other -> other
        end
    end
  end

  # Broadcasts on new content and when a feed starts or stops failing. The sidebar marks failing
  # feeds. A repeated failure or an unchanged response broadcasts nothing.
  defp news?({:ok, _refreshed}, _feed), do: true
  defp news?({:unchanged, _refreshed}, feed), do: feed.last_error != nil
  defp news?({:error, _reason}, feed), do: feed.last_error == nil

  defp refresh_feed(feed, on_new) do
    headers =
      [{"if-none-match", feed.etag}, {"if-modified-since", feed.last_modified}]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    # `wait` is seconds or nil. It can delay the next check, never advance it.
    case Discovery.poll(feed.url, headers) do
      # Keeps the subscribed URL when the endpoint redirects.
      {{:ok, preview}, wait} ->
        %{preview | url: feed.url} |> store_entries(on_new, wait) |> compared_with(feed)

      # A 304 broadcasts nothing. Each broadcast reloads every open library view.
      {:not_modified, wait} ->
        now = DateTime.utc_now()

        feed
        |> Ecto.Changeset.change(
          last_checked_at: now,
          last_error: nil,
          next_check_at: next_check(feed.id, now, newest(feed.id), wait)
        )
        |> Repo.update()
        |> case do
          {:ok, feed} -> {:unchanged, feed}
          other -> other
        end

      # A failure carries no publishing date. The next check uses the base interval, or the
      # server's wait when longer.
      {{:error, reason}, wait} ->
        now = DateTime.utc_now()
        # Logs the feed's title and host to identify it. The full URL is omitted, because a
        # private feed URL may contain a token.
        Logger.warning("feed refresh failed",
          feed_id: feed.id,
          feed_title: feed.title,
          host: URI.parse(feed.url).host,
          reason: reason
        )

        Repo.update_all(from(f in Feed, where: f.id == ^feed.id),
          set: [
            last_checked_at: now,
            last_error: to_string(reason),
            next_check_at: retry_check(now, wait)
          ]
        )

        # With a server wait, `:busy` prevents a job retry before `next_check_at`.
        if wait, do: {:error, :busy}, else: {:error, reason}
    end
  end

  # A 200 response that changes nothing broadcasts nothing, like a 304. Changes to `title`,
  # `icon_url` or `page_url` count as changes, as entry changes do.
  defp compared_with({:ok, {stored, 0}}, feed)
       when stored.title == feed.title and stored.icon_url == feed.icon_url and
              stored.page_url == feed.page_url,
       do: {:unchanged, stored}

  defp compared_with({:ok, {stored, _written}}, _feed), do: {:ok, stored}
  defp compared_with(other, _feed), do: other

  @replaced_entry_fields [:title, :media_url, :video_id, :embed_url, :published_at]
  # The kept fields that make up `search_text`.
  @text_fields [:description, :description_format, :excerpt]
  @kept_entry_fields [
    :audio_url,
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
    entries = Enum.uniq_by(entries, & &1.external_id)
    kept = kept_text(feed_id, entries)

    rows =
      Enum.map(entries, fn entry ->
        entry
        |> Map.take([:external_id, :short | @replaced_entry_fields ++ @kept_entry_fields])
        |> Map.put_new(:short, false)
        |> Map.merge(%{feed_id: feed_id, inserted_at: now, updated_at: now})
        |> Map.update(:published_at, nil, &microseconds/1)
        |> Map.put(:search_text, SearchText.of(with_kept_text(entry, kept)))
      end)

    {written, _} =
      Repo.insert_all(Entry, rows,
        on_conflict: keep_content(),
        conflict_target: [:feed_id, :external_id]
      )

    # Inserted rows carry this exact `inserted_at`. Updated rows keep their original value.
    new =
      Repo.all(
        from e in Entry,
          where: e.feed_id == ^feed_id and e.inserted_at == ^now,
          order_by: [asc: e.published_at, asc: e.id],
          select: e.id
      )

    {written, new}
  end

  # `search_text` must match the row after the upsert. The upsert keeps stored text fields a poll
  # omits, so those entries' stored values are read here. The feed upsert earlier in this
  # transaction locks the feed row. A concurrent refresh cannot write between this read and the
  # entry upsert.
  defp kept_text(feed_id, entries) do
    case for(e <- entries, Enum.any?(@text_fields, &is_nil(e[&1])), do: e.external_id) do
      [] ->
        %{}

      ids ->
        Repo.all(
          from e in Entry,
            where: e.feed_id == ^feed_id and e.external_id in ^ids,
            select: {e.external_id, map(e, ^@text_fields)}
        )
        |> Map.new()
    end
  end

  # Applies the upsert's COALESCE in Elixir, so `search_text` matches the stored row.
  defp with_kept_text(entry, kept) do
    Map.merge(entry, Map.get(kept, entry.external_id, %{}), fn _field, new, old -> new || old end)
  end

  # Title, media location and publishing date are always replaced. A changed media URL means the
  # file moved.
  # The audio-only file, artwork, duration, description, excerpt, page URL and chapters keep
  # their stored value when a poll omits them. A feed that trims its document must not erase older
  # episodes' data. The feed's `icon_url` follows the same rule.
  #
  # The update is skipped when no value would change. A rewrite costs a new row version, WAL and
  # a dead tuple on every poll of a feed without ETag or Last-Modified. The guard compares the
  # whole row null-safely against the values the update would set. Guard and update list their
  # columns separately. Each column has a test that changes only it and expects a write. A column
  # missing from the guard fails its test.
  #
  # `short` is never reset to false. The channel's Shorts feed lists only its latest Shorts.
  # A missing flag does not mean the entry is not a Short.
  #
  # SQLite stores a nil chapter list as the JSON text `null`, not as SQL NULL. `NULLIF` against
  # an equally dumped nil turns it into NULL there. On Postgres it is a no-op.
  defp keep_content do
    from(e in Entry,
      where:
        fragment(
          """
          (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) IS DISTINCT FROM
          (EXCLUDED.title, EXCLUDED.media_url, COALESCE(EXCLUDED.audio_url, ?),
           EXCLUDED.video_id, EXCLUDED.embed_url, EXCLUDED.published_at,
           COALESCE(EXCLUDED.image_url, ?), COALESCE(EXCLUDED.duration, ?),
           COALESCE(EXCLUDED.description, ?), COALESCE(EXCLUDED.description_format, ?),
           COALESCE(EXCLUDED.excerpt, ?), COALESCE(EXCLUDED.page_url, ?),
           COALESCE(NULLIF(EXCLUDED.chapters, ?), ?), COALESCE(EXCLUDED.chapters_url, ?),
           EXCLUDED.short OR ?)
          """,
          e.title,
          e.media_url,
          e.audio_url,
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
          e.short,
          e.audio_url,
          e.image_url,
          e.duration,
          e.description,
          e.description_format,
          e.excerpt,
          e.page_url,
          type(^nil, {:array, :map}),
          e.chapters,
          e.chapters_url,
          e.short
        ),
      update: [
        set: [
          title: fragment("EXCLUDED.title"),
          media_url: fragment("EXCLUDED.media_url"),
          audio_url: fragment("COALESCE(EXCLUDED.audio_url, ?)", e.audio_url),
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
          # A new `chapters_url` clears the cached chapters, so they are fetched again.
          # A poll without a chapters URL keeps the cached chapters.
          chapters:
            fragment(
              "CASE WHEN NULLIF(EXCLUDED.chapters, ?) IS NULL AND EXCLUDED.chapters_url IS NOT NULL AND EXCLUDED.chapters_url IS DISTINCT FROM ? THEN NULL ELSE COALESCE(NULLIF(EXCLUDED.chapters, ?), ?) END",
              type(^nil, {:array, :map}),
              e.chapters_url,
              type(^nil, {:array, :map}),
              e.chapters
            ),
          chapters_url: fragment("COALESCE(EXCLUDED.chapters_url, ?)", e.chapters_url),
          short: fragment("EXCLUDED.short OR ?", e.short),
          # Derived from the guarded columns, kept text included, so the guard omits it.
          search_text: fragment("EXCLUDED.search_text"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # `insert_all` skips schema casting. Parsed timestamps must already have microsecond precision.
  defp microseconds(nil), do: nil
  defp microseconds(date), do: %{date | microsecond: {elem(date.microsecond, 0), 6}}
end
