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
  alias Sikio.Feeds.Schedule
  alias Sikio.Feeds.SearchText
  alias Sikio.Library.Events
  alias Sikio.Repo

  @feed_fields [:title, :etag, :last_modified, :last_checked_at, :last_error, :updated_at]

  # Everything the source just said replaces what was stored, except the picture and the website.
  # An absent value is no statement that the source has none. YouTube's Atom feed names no
  # artwork, and a podcast may leave out its link once. A dropped website stays until another
  # replaces it. One row is written here, so leaving a column out of the list says exactly that.
  defp replaced_feed_fields(attrs),
    do: Enum.filter([:icon_url, :page_url], &is_binary(attrs[&1])) ++ @feed_fields

  @doc "How often a feed is asked, in minutes: an hour unless the operator sets `FEED_POLL_MINUTES`."
  def poll_minutes, do: Application.get_env(:sikio, :feed_poll_minutes, 60)

  @doc """
  Stores a source and its entries, inserting what is new and updating what changed.

  `on_new` is called with the feed's id and the ids of the entries that are new, inside the same
  transaction, when there are any. The library sends them where its subscriptions say.
  """
  def store(preview, on_new \\ &ignore/2) do
    with {:ok, {feed, _written}} <- store_entries(preview, on_new), do: {:ok, feed}
  end

  defp ignore(_feed_id, _entry_ids), do: :ok

  defp announce(_on_new, _feed_id, []), do: :ok
  defp announce(on_new, feed_id, entry_ids), do: on_new.(feed_id, entry_ids)

  # When the feed is asked next, by the age of its newest entry as stored now.
  defp schedule_next(feed_id, now, wait) do
    next = next_check(now, newest(feed_id), wait)
    Repo.update_all(from(f in Feed, where: f.id == ^feed_id), set: [next_check_at: next])
    next
  end

  defp next_check(now, newest, wait) do
    Schedule.spread(now, Schedule.next_check(now, newest, poll_minutes(), wait))
  end

  defp newest(feed_id),
    do: Repo.one(from e in Entry, where: e.feed_id == ^feed_id, select: max(e.published_at))

  # The feed and how many of its entries were inserted or actually changed.
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

  @doc """
  Fetches a source again. `on_new` hears of new entries as with `store/2`.

  A server that failed and named when to come back answers `{:error, :busy}`, so the caller does
  not retry before the feed's next check.
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

  # Subscribers hear of new content, and of a source that starts failing or recovers: the sidebar
  # marks a failing one. Failing again, or answering the same, is nothing new.
  defp news?({:ok, _refreshed}, _feed), do: true
  defp news?({:unchanged, _refreshed}, feed), do: feed.last_error != nil
  defp news?({:error, _reason}, feed), do: feed.last_error == nil

  defp refresh_feed(feed, on_new) do
    headers =
      [{"if-none-match", feed.etag}, {"if-modified-since", feed.last_modified}]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    # The server's wait, in seconds or nil, only ever postpones the next request.
    case Discovery.poll(feed.url, headers) do
      # Keep the original stable subscription URL even when its endpoint redirects.
      {{:ok, preview}, wait} ->
        %{preview | url: feed.url} |> store_entries(on_new, wait) |> compared_with(feed)

      # Nothing changed, so nobody is told. Each notification costs every open library a reload.
      {:not_modified, wait} ->
        now = DateTime.utc_now()

        feed
        |> Ecto.Changeset.change(
          last_checked_at: now,
          last_error: nil,
          next_check_at: next_check(now, newest(feed.id), wait)
        )
        |> Repo.update()
        |> case do
          {:ok, feed} -> {:unchanged, feed}
          other -> other
        end

      # A failure says nothing about the feed's pace, so it is asked again at the base interval,
      # or later when the server said so.
      {{:error, reason}, wait} ->
        now = DateTime.utc_now()

        Repo.update_all(from(f in Feed, where: f.id == ^feed.id),
          set: [
            last_checked_at: now,
            last_error: to_string(reason),
            next_check_at: next_check(now, nil, wait)
          ]
        )

        # A server that named its wait is asked again then, so the job is not retried before.
        if wait, do: {:error, :busy}, else: {:error, reason}
    end
  end

  # A document that repeats what is stored notifies nobody, like a 304. What a reader sees of the
  # source itself, its name, picture and website, counts as much as its entries.
  defp compared_with({:ok, {stored, 0}}, feed)
       when stored.title == feed.title and stored.icon_url == feed.icon_url and
              stored.page_url == feed.page_url,
       do: {:unchanged, stored}

  defp compared_with({:ok, {stored, _written}}, _feed), do: {:ok, stored}
  defp compared_with(other, _feed), do: other

  @replaced_entry_fields [:title, :media_url, :video_id, :embed_url, :published_at]
  # The kept fields that the searched text is made of.
  @text_fields [:description, :description_format, :excerpt]
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

    # A row inserted now carries this moment; one that was there keeps its own.
    new =
      Repo.all(
        from e in Entry,
          where: e.feed_id == ^feed_id and e.inserted_at == ^now,
          order_by: [asc: e.published_at, asc: e.id],
          select: e.id
      )

    {written, new}
  end

  # The text searched has to be the one the row ends up with. Notes and an excerpt a poll left
  # out stay stored, so they are read back for exactly those entries. The feed's upsert before
  # this holds its row, so a second refresh of the feed cannot write between read and upsert.
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

  # The same COALESCE the upsert applies, so the text follows the row.
  defp with_kept_text(entry, kept) do
    Map.merge(entry, Map.get(kept, entry.external_id, %{}), fn _field, new, old -> new || old end)
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
  #
  # A Short stays one. The channel's Shorts feed names only its latest Shorts. A poll without the
  # mark says nothing about an entry.
  #
  # SQLite stores a list of no chapters as the JSON text `null` rather than as NULL. `NULLIF`
  # against a nil dumped the same way turns it back into NULL there, and is a no-op on Postgres.
  defp keep_content do
    from(e in Entry,
      where:
        fragment(
          """
          (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) IS DISTINCT FROM
          (EXCLUDED.title, EXCLUDED.media_url, EXCLUDED.video_id, EXCLUDED.embed_url,
           EXCLUDED.published_at, COALESCE(EXCLUDED.image_url, ?), COALESCE(EXCLUDED.duration, ?),
           COALESCE(EXCLUDED.description, ?), COALESCE(EXCLUDED.description_format, ?),
           COALESCE(EXCLUDED.excerpt, ?), COALESCE(EXCLUDED.page_url, ?),
           COALESCE(NULLIF(EXCLUDED.chapters, ?), ?), COALESCE(EXCLUDED.chapters_url, ?),
           EXCLUDED.short OR ?)
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
          e.short,
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
          # fetched again. A poll that names no file names no other one.
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
          # Derived from the columns above, notes kept included, so the guard need not compare it.
          search_text: fragment("EXCLUDED.search_text"),
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
