# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library do
  @moduledoc """
  Account-scoped subscriptions, feed entries and their listing.

  Every function on an account's data takes the account first and scopes its query to it.
  `deliver/2`, `due_feed_ids/0` and `active_feed?/1` operate on feeds across all accounts.
  Feed content is shared. Subscriptions and playback progress belong to one account.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Entry
  alias Sikio.Library.Events
  alias Sikio.Library.Subscription
  alias Sikio.Playback.State
  alias Sikio.Repo
  alias Sikio.Tags

  @doc "Returns the entry with this id if the account can see it, otherwise `nil`."
  def entry(%User{id: user_id}, id),
    do: with_id(id, &Repo.one(from e in entry_query(user_id), where: e.id == ^&1))

  @doc """
  Returns the id of an entry the account can see, or `nil`.

  Writes call this for authorization on every request. They do not trust the request that started
  the player. The query joins subscriptions and selects only the entry id.
  """
  def visible_entry_id(%User{id: user_id}, id),
    do:
      with_id(
        id,
        &Repo.one(from e in subscribed_entries(user_id), where: e.id == ^&1, select: e.id)
      )

  @doc "Returns a query for the ids of entries the account can see, for use as a subquery."
  def visible_entry_ids(%User{id: user_id}),
    do: from(e in subscribed_entries(user_id), select: e.id)

  @doc "Returns a query for the ids of entries the account's lists show, without hidden Shorts."
  def listed_entry_ids(%User{id: user_id}),
    do: from(e in listed_entries(user_id), select: e.id)

  def subscribe(%User{id: user_id}, preview) do
    result =
      Repo.transaction(fn ->
        # The subscription is inserted after the store, so `deliver/2` does not see it.
        # The feed's current entries stay in this account's inbox.
        # Existing subscriptions receive only the new entries.
        with {:ok, feed} <- Feeds.store(preview, &deliver/2),
             {:ok, subscription} <-
               Repo.insert(
                 Subscription.changeset(%Subscription{user_id: user_id, feed_id: feed.id}, %{}),
                 on_conflict: :nothing,
                 conflict_target: [:user_id, :feed_id]
               ) do
          load_subscription(subscription, user_id, feed.id)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, subscription} -> Events.feed_updated(subscription.feed_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Updates a subscription's settings: a custom name, the delivery of new entries, and Shorts.
  A blank name falls back to the feed title. Returns `{:error, :not_found}` for another
  account's subscription. A successful update with changes broadcasts
  `{:subscription_changed, subscription_id}` to the account.
  """
  def update_subscription(account, id, attrs) do
    case owned(account, id) do
      nil ->
        {:error, :not_found}

      subscription ->
        changeset = Subscription.settings_changeset(subscription, attrs)
        changeset |> Repo.update() |> tap(&announce(account, changeset, &1))
    end
  end

  # Every open view reloads on this broadcast, so an update without changes sends none.
  defp announce(account, %{changes: changes}, {:ok, updated}) when changes != %{},
    do: Events.broadcast(account, {:subscription_changed, updated.id})

  defp announce(_account, _changeset, _result), do: :ok

  @doc """
  Applies each subscription's `delivery` to a feed's new entries.
  `:queue` appends them to the account's queue, oldest first. `:skip` archives them.
  `:inbox` needs no row, since an entry without a playback row counts as new.
  Runs inside the transaction that stores the entries.
  """
  def deliver(feed_id, entry_ids) do
    now = DateTime.utc_now()
    # Subscriptions with `shorts: false` receive no Shorts.
    shorts = Repo.all(from e in Entry, where: e.id in ^entry_ids and e.short, select: e.id)
    without_shorts = entry_ids -- shorts

    Repo.all(
      from s in Subscription,
        where: s.feed_id == ^feed_id and s.delivery != :inbox,
        # Queue locks are held until the refresh commits.
        # A fixed lock order prevents deadlocks between concurrent refreshes.
        order_by: s.user_id,
        select: {s.user_id, s.delivery, s.shorts}
    )
    |> Enum.each(fn {user_id, delivery, with_shorts} ->
      ids = if with_shorts, do: entry_ids, else: without_shorts
      lock_queue(user_id)
      Repo.insert_all(State, delivered(user_id, delivery, ids, now), on_conflict: :nothing)
    end)
  end

  @doc """
  Locks the account's user row until the transaction ends, see `Sikio.Repo.for_no_key_update/1`.
  Every change that computes a queue rank takes this lock first.
  Two concurrent changes therefore cannot assign the same rank.
  """
  def lock_queue(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.id)
    |> Repo.for_no_key_update()
    |> Repo.one()
  end

  # One account's playback rows for new entries: ranked after its queue, or archived.
  defp delivered(user_id, delivery, entry_ids, now) do
    last =
      Repo.one(
        from p in State,
          where: p.user_id == ^user_id and not is_nil(p.queue_rank),
          select: max(p.queue_rank)
      ) || 0.0

    entry_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {entry_id, n} ->
      Map.merge(
        %{user_id: user_id, entry_id: entry_id, inserted_at: now, updated_at: now},
        landing(delivery, last + n, now)
      )
    end)
  end

  defp landing(:queue, rank, _now), do: %{status: :new, queue_rank: rank}
  defp landing(:skip, _rank, now), do: %{status: :archived, completed_at: now}

  def subscriptions(%User{id: user_id}) do
    Repo.all(
      from s in Subscription,
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at, desc: s.id],
        preload: [:feed]
    )
  end

  @doc """
  Returns the origins of the PeerTube instances the account subscribes to, sorted.

  A PeerTube video embeds from the instance that hosts it. No fixed instance list exists.
  The content security policy derives its allowed frame origins from this list.
  """
  def player_origins(%User{id: user_id}) do
    Repo.all(
      from s in Subscription,
        join: f in assoc(s, :feed),
        where: s.user_id == ^user_id and f.kind == :peertube,
        distinct: true,
        select: f.url
    )
    |> Enum.map(&origin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp origin(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) -> "#{scheme}://#{host}"
      _ -> nil
    end
  end

  @doc """
  Returns the account's entries matching `filters`, in the order `sorted_by/1` names.
  The queue sorts by rank. Other lists sort newest first, undated last.

  `:limit` caps the result, 100 by default. `:after` takes the last entry a list already shows.
  The next page uses keyset pagination on the sort key and the id.
  An entry inserted between pages causes no duplicates or gaps.
  """
  def entries(%User{id: user_id}, filters \\ %{}, opts \\ []) do
    by = sorted_by(filters)
    query = user_id |> filtered_entries(filters) |> behind(by, opts[:after])

    order =
      if by == :queue,
        do: [asc: key(by), asc: dynamic([e], e.id)],
        else: [desc_nulls_last: key(by), desc: dynamic([e], e.id)]

    Repo.all(from e in query, order_by: ^order, limit: ^Keyword.get(opts, :limit, 100))
  end

  @doc """
  Returns the sort key for `filters`: `:queue` for the queue, `:finished` for heard entries,
  `:published` for everything else.
  """
  def sorted_by(filters) do
    case normalize_filters(filters)["status"] do
      "queue" -> :queue
      "heard" -> :finished
      _ -> :published
    end
  end

  @doc "Returns `entry`'s date for the sort key `by`, or nil when it has none."
  def sort_date(entry, :published), do: entry.published_at
  def sort_date(%{playback: %{completed_at: at}}, :finished), do: at
  def sort_date(_entry, _by), do: nil

  @doc """
  Whether `a` sorts before `b` under the sort key `by`.
  The queue sorts by ascending rank. Dates sort descending, undated last. The id breaks ties.
  """
  def before?(a, b, :queue), do: {rank(a), a.id} < {rank(b), b.id}

  def before?(a, b, by) do
    case {sort_date(a, by), sort_date(b, by)} do
      {nil, %DateTime{}} ->
        false

      {%DateTime{}, nil} ->
        true

      {x, y} ->
        if x && DateTime.compare(x, y) != :eq, do: DateTime.after?(x, y), else: a.id > b.id
    end
  end

  defp rank(%{playback: %{queue_rank: rank}}) when is_number(rank), do: rank
  defp rank(_entry), do: :infinity

  defp key(:published), do: dynamic([e], e.published_at)
  defp key(:finished), do: dynamic([e, s, p], p.completed_at)
  defp key(:queue), do: dynamic([e, s, p], p.queue_rank)

  # Keyset pagination: the entries after `entry` in the list's order.
  defp behind(query, _by, nil), do: query

  defp behind(query, :queue, %{id: id} = entry) do
    rank = rank(entry)
    where(query, [e, s, p], p.queue_rank > ^rank or (p.queue_rank == ^rank and e.id > ^id))
  end

  defp behind(query, by, %{id: id} = entry) do
    key = key(by)

    case sort_date(entry, by) do
      nil ->
        where(query, ^dynamic([e], is_nil(^key) and e.id < ^id))

      # The key is an interpolated dynamic, so Ecto cannot infer the value's type.
      at ->
        at = dynamic(type(^at, :utc_datetime_usec))
        where(query, ^dynamic([e], ^key < ^at or (^key == ^at and e.id < ^id) or is_nil(^key)))
    end
  end

  @doc """
  Returns the account's entry counts grouped by feed and status, from one query.

  `tally/3` sums these rows for the active filters.
  An entry without a playback row counts as new.
  """
  def counts(%User{id: user_id}) do
    Repo.all(
      from [e, s, p] in scoped_entries(user_id),
        group_by: [e.feed_id, p.status, is_nil(p.queue_rank)],
        select: {e.feed_id, p.status, is_nil(p.queue_rank), count(e.id)}
    )
    |> Enum.map(fn {feed_id, status, unqueued, count} ->
      %{feed_id: feed_id, views: views(status, unqueued), count: count}
    end)
  end

  # The lists besides "all" that show an entry, matching the filters in `filtered_entries/2`.
  # The queue shows every queued entry. The inbox shows new entries outside the queue.
  # Heard entries show in the history, queued or not.
  # Archived entries and in-progress entries outside the queue show only under "all".
  defp views(:heard, true), do: [:heard]
  defp views(:heard, false), do: [:queue, :heard]
  defp views(_status, false), do: [:queue]
  defp views(status, true) when status in [nil, :new], do: [:inbox]
  defp views(_status, true), do: []

  @doc """
  Returns the item count for each sidebar link under the active filters.

  Each count applies the other active filters and replaces only its own.
  Source and tag counts include only new entries unless a status filter is set.
  A tag counts the feeds that `tag_feeds` maps it to.
  """
  def tally(rows, filters, tag_feeds \\ %{}) do
    filters = normalize_filters(filters)

    tagged =
      if filters["tag"] == "",
        do: [],
        else: Map.get(tag_feeds, String.to_integer(filters["tag"]), [])

    beside = fn own -> Enum.filter(rows, &matches_except?(&1, filters, own, tagged)) end
    sources = Map.new(rows, &{&1.feed_id, 0})

    # Source and tag counts ignore both the source and the tag filter.
    new_or_chosen =
      beside.([:source, :tag]) |> Enum.filter(&(filters["status"] != "" or :inbox in &1.views))

    by_feed = sum_by(new_or_chosen, :feed_id)
    listed = beside.([:status])

    # An entry can appear in two lists. Each list counts it, and `:all` counts it once.
    Map.new([:inbox, :queue, :heard], fn view ->
      {view, listed |> Enum.filter(&(view in &1.views)) |> Enum.sum_by(& &1.count)}
    end)
    |> Map.put(:all, Enum.sum_by(listed, & &1.count))
    |> Map.put(:sources, Map.merge(sources, by_feed))
    |> Map.put(
      :tags,
      Map.new(tag_feeds, fn {tag, feeds} ->
        {tag, feeds |> Enum.uniq() |> Enum.map(&Map.get(by_feed, &1, 0)) |> Enum.sum()}
      end)
    )
  end

  @doc "Whether the account's list for `filters` contains the entry."
  def listed?(%User{id: user_id}, filters, id) do
    with_id(id, fn id ->
      user_id
      |> filtered_entries(filters)
      |> exclude(:preload)
      |> exclude(:select)
      |> where([e], e.id == ^id)
      |> Repo.exists?()
    end) || false
  end

  @doc """
  Returns a query for the ids of every entry the list for `filters` shows, ignoring pagination.
  Callers use it as a subquery, so marking a whole list never loads its ids.
  """
  def listed_ids(%User{id: user_id}, filters) do
    user_id
    |> filtered_entries(filters)
    |> exclude(:preload)
    |> exclude(:select)
    |> select([e], e.id)
  end

  @doc "Returns how many entries match `filters`, ignoring pagination."
  def count(%User{id: user_id}, filters) do
    user_id
    |> filtered_entries(filters)
    |> exclude(:preload)
    |> exclude(:select)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  @doc "Returns the total count for `filters`, read from their `tally/3`."
  def total(tally, filters) do
    status = normalize_filters(filters)["status"]
    Map.fetch!(tally, if(status == "", do: :all, else: String.to_existing_atom(status)))
  end

  defp sum_by(rows, key) do
    Enum.reduce(rows, %{}, fn row, sums ->
      Map.update(sums, Map.fetch!(row, key), row.count, &(&1 + row.count))
    end)
  end

  defp matches_except?(row, filters, own, tagged) do
    Enum.all?([:source, :tag, :status] -- own, fn
      :source -> filters["source"] in ["", to_string(row.feed_id)]
      :tag -> filters["tag"] == "" or row.feed_id in tagged
      :status -> filters["status"] in ["" | Enum.map(row.views, &to_string/1)]
    end)
  end

  @doc """
  Reduces request parameters to `status`, `source`, `tag` and `q`, dropping everything else.

  This lives here, not in the view, because the same values reach database queries.
  An unrecognised value becomes an empty string, which means no filter.
  """
  def normalize_filters(params) do
    %{
      "status" => params["status"] |> renamed() |> choice(~w(inbox queue heard)),
      "source" => source_id(params["source"]),
      "tag" => source_id(params["tag"]),
      "q" => search_text(params["q"])
    }
  end

  # Search input, trimmed and capped at 100 characters.
  defp search_text(text) when is_binary(text), do: text |> String.trim() |> String.slice(0, 100)
  defp search_text(_text), do: ""

  # Former status names, still present in old URLs and links.
  defp renamed("new"), do: "inbox"
  defp renamed("in_progress"), do: "queue"
  defp renamed("completed"), do: "heard"
  defp renamed(status), do: status

  defp choice(value, values), do: if(value in values, do: value, else: "")

  # A source's id from an address: a positive 64-bit integer as text, or "" for anything else.
  defp source_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> Integer.to_string(id)
      _ -> ""
    end
  end

  defp source_id(_), do: ""

  # A source filter matches one feed.
  # A tag filter matches the feeds of the account's subscriptions with that tag.
  defp in_place(query, _user_id, %{"source" => source}) when source != "",
    do: where(query, [e], e.feed_id == ^String.to_integer(source))

  defp in_place(query, user_id, %{"tag" => tag}) when tag != "",
    do: where(query, [e], e.feed_id in subquery(Tags.feed_ids(%User{id: user_id}, tag)))

  defp in_place(query, _user_id, _filters), do: query

  defp filtered_entries(user_id, params) do
    filters = normalize_filters(params)
    query = user_id |> entry_query() |> in_place(user_id, filters)

    query =
      case filters["status"] do
        "" ->
          query

        # An entry without a playback row counts as new.
        "inbox" ->
          where(query, [e, s, p], (is_nil(p.id) or p.status == :new) and is_nil(p.queue_rank))

        "queue" ->
          where(query, [e, s, p], not is_nil(p.queue_rank))

        "heard" ->
          where(query, [e, s, p], p.status == :heard)
      end

    matching(query, filters["q"])
  end

  # Matches title, notes and excerpt as Sikio.Feeds.SearchText stores them: lowercase, no markup.
  # The input is lowercased too, so matching ignores case.
  # Pattern characters in the input are escaped.
  defp matching(query, ""), do: query

  defp matching(query, text), do: where(query, [e], ^containing(String.downcase(text)))

  # Both databases serve the search from a trigram index.
  # PostgreSQL indexes the column, and `LIKE` uses that index.
  # SQLite keeps the index in a separate full-text table.
  # That table uses it for `GLOB` and for `LIKE` without `ESCAPE`.
  # SQLite therefore queries that table with `GLOB`.
  # Each pattern language has its own wildcards; those in the input are escaped.
  defp containing(text) do
    if Sikio.Repo.postgres?(), do: postgres_containing(text), else: sqlite_containing(text)
  end

  defp sqlite_containing(text) do
    pattern = "*" <> String.replace(text, ["[", "*", "?"], &("[" <> &1 <> "]")) <> "*"

    dynamic(
      [e],
      fragment(
        "? IN (SELECT rowid FROM entries_search WHERE search_text GLOB ?)",
        e.id,
        ^pattern
      )
    )
  end

  defp postgres_containing(text) do
    pattern = "%" <> String.replace(text, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
    dynamic([e], fragment("? LIKE ? ESCAPE '\\'", e.search_text, ^pattern))
  end

  # The subscription join scopes entries to the account.
  # Every entry query starts here, including the authorization check on each write.
  defp subscribed_entries(user_id) do
    from e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id
  end

  # Entries the account's lists show. Shorts show only where the subscription enables them.
  # Hiding applies to lists only, so a player can still save progress on a Short.
  defp listed_entries(user_id) do
    from [e, s] in subscribed_entries(user_id), where: s.shorts or not e.short
  end

  # The left join adds this account's playback row to the shared entry.
  defp scoped_entries(user_id) do
    from [e, s] in listed_entries(user_id),
      left_join: p in State,
      on: p.entry_id == e.id and p.user_id == ^user_id,
      join: f in assoc(e, :feed)
  end

  defp entry_query(user_id) do
    from [e, s, p, f] in scoped_entries(user_id),
      select_merge: %{playback: p, source_name: coalesce(s.name, f.title)},
      # Preloads from the join above. An unbound `preload: [:feed]` runs a second query for feeds.
      # Every library page and every progress save would pay for that query.
      preload: [feed: f]
  end

  def pause(account, id, paused) when is_boolean(paused) do
    case owned(account, id) do
      nil -> {:error, :not_found}
      subscription -> subscription |> Subscription.changeset(%{paused: paused}) |> Repo.update()
    end
  end

  defp load_subscription(%Subscription{id: nil}, user_id, feed_id) do
    Repo.get_by!(Subscription, user_id: user_id, feed_id: feed_id) |> Repo.preload(:feed)
  end

  defp load_subscription(subscription, _user_id, _feed_id), do: Repo.preload(subscription, :feed)

  @doc """
  Deletes the account's subscription. The shared feed and its entries remain.

  Other accounts may still subscribe to the feed. Playback rows remain too.
  A later resubscription therefore restores the account's progress.
  Broadcasts `{:subscription_removed, feed_id}` to the account on success.
  """
  def unsubscribe(account, id) do
    case owned(account, id) do
      nil ->
        {:error, :not_found}

      subscription ->
        result = Repo.delete(subscription)

        if match?({:ok, _}, result),
          do: Events.broadcast(account, {:subscription_removed, subscription.feed_id})

        result
    end
  end

  @doc """
  Returns the ids of feeds with an unpaused subscription whose next check is due.

  Each refresh sets `next_check_at`, see `Sikio.Feeds.Schedule`.
  A feed without `next_check_at` is due immediately.
  The refresh writes it shortly after the scheduler run that queued the feed.
  A one-minute margin keeps the feed from slipping to the following run.
  """
  def due_feed_ids do
    soon = DateTime.add(DateTime.utc_now(), 1, :minute)

    Repo.all(
      from s in Subscription,
        join: f in assoc(s, :feed),
        where: not s.paused,
        where: is_nil(f.next_check_at) or f.next_check_at <= ^soon,
        select: s.feed_id,
        distinct: true
    )
  end

  def active_feed?(id),
    do: Repo.exists?(from s in Subscription, where: s.feed_id == ^id and not s.paused)

  defp owned(%User{id: user_id}, id),
    do: with_id(id, &Repo.get_by(Subscription, id: &1, user_id: user_id))

  # An invalid id returns nil instead of raising.
  defp with_id(id, fun) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> fun.(id)
      _ -> nil
    end
  end
end
