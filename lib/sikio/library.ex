# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library do
  @moduledoc """
  Account-scoped subscriptions and imported media.

  Every function here takes the account as its first argument, and every query is written against
  it rather than filtered afterwards. Feed content is shared; what an account subscribed to, and
  how far it got, is not.
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

  @doc "The one entry with this id that the account is allowed to see, or `nil`."
  def entry(%User{id: user_id}, id),
    do: with_id(id, &Repo.one(from e in entry_query(user_id), where: e.id == ^&1))

  @doc """
  The id of an entry the account is allowed to see, or `nil`.

  This is the authorization for every write, so it is asked again each time rather than trusted
  from the request that started a player. It reads the subscription only, not the item.
  """
  def visible_entry_id(%User{id: user_id}, id),
    do:
      with_id(
        id,
        &Repo.one(from e in subscribed_entries(user_id), where: e.id == ^&1, select: e.id)
      )

  @doc "A query for the ids of the entries the account is allowed to see, to filter other queries by."
  def visible_entry_ids(%User{id: user_id}),
    do: from(e in subscribed_entries(user_id), select: e.id)

  def subscribe(%User{id: user_id}, preview) do
    result =
      Repo.transaction(fn ->
        # The subscription is made after the store, so what the source holds now stays in the
        # inbox for this account, while others' subscriptions take what is new to them.
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
  Changes a subscription's own settings: a name of the account's own, blank for the feed's
  title, and where what its source publishes next goes.
  """
  def update_subscription(account, id, attrs) do
    case owned(account, id) do
      nil -> {:error, :not_found}
      subscription -> subscription |> Subscription.settings_changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Sends a source's new entries where each subscription to it says: to the end of its account's
  queue, oldest first, or to the archive. The inbox needs nothing, since an entry nobody has
  opened is new. Runs inside the transaction that stores the entries.
  """
  def deliver(feed_id, entry_ids) do
    now = DateTime.utc_now()

    Repo.all(
      from s in Subscription,
        where: s.feed_id == ^feed_id and s.delivery != :inbox,
        # The refresh's transaction holds every queue until it commits, so two refreshes take
        # them in one order.
        order_by: s.user_id,
        select: {s.user_id, s.delivery}
    )
    |> Enum.each(fn {user_id, delivery} ->
      lock_queue(user_id)
      Repo.insert_all(State, delivered(user_id, delivery, entry_ids, now), on_conflict: :nothing)
    end)
  end

  @doc """
  Holds the account's queue until the transaction ends. Every change that computes a rank takes
  it first, so two changes cannot give two items one place.
  """
  def lock_queue(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.id)
    |> Repo.for_no_key_update()
    |> Repo.one()
  end

  # One account's progress rows for new entries: queued after what its queue holds, or archived.
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
  The origins whose own players this account may be shown.

  A PeerTube video is played by the instance that holds it, and there is no list of instances
  to know in advance. What this account subscribed to is the list, so the policy that frames
  them is derived from it rather than guessed at.
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
  The account's entries under `filters`, newest first and undated last.

  `:limit` caps how many come back, 100 by default. `:after` names the last entry a list already
  shows, and the batch continues behind it by date and then id, so nothing repeats or is skipped
  when an episode arrives in between.
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
  What a list with `filters` runs by: the queue by its own order, what was heard by when it was
  heard, everything else by when it was published.
  """
  def sorted_by(filters) do
    case normalize_filters(filters)["status"] do
      "queue" -> :queue
      "heard" -> :finished
      _ -> :published
    end
  end

  @doc "The date `entry` has in a list that runs `by` it, or nil when it has none."
  def sort_date(entry, :published), do: entry.published_at
  def sort_date(%{playback: %{completed_at: at}}, :finished), do: at
  def sort_date(_entry, _by), do: nil

  @doc """
  Whether `a` comes before `b` in a list that runs `by` something: the queue first to last, a
  date later first, undated last.
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

  # The entries after `entry` in the list's order, for loading the next batch.
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

      # Typed, because a key that is itself interpolated tells Ecto nothing about the value.
      at ->
        at = dynamic(type(^at, :utc_datetime_usec))
        where(query, ^dynamic([e], ^key < ^at or (^key == ^at and e.id < ^id) or is_nil(^key)))
    end
  end

  @doc """
  This account's entries grouped by source and status, from one query.

  The rows are what `tally/3` adds up for whichever filters are in force. An entry nobody has
  opened has no progress row and is counted as new.
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

  # The lists an entry shows in besides all items, as their queries choose them: the queue holds
  # whatever stands in it, the inbox what is new beside it, the history what was heard, queued
  # again or not. What is archived, or under way outside the queue, shows only among all items.
  defp views(:heard, true), do: [:heard]
  defp views(:heard, false), do: [:queue, :heard]
  defp views(_status, false), do: [:queue]
  defp views(status, true) when status in [nil, :new], do: [:inbox]
  defp views(_status, true), do: []

  @doc """
  How many items each link in the sidebar shows, under the filters in force.

  Each count honours the filters its link keeps and replaces only its own. A source counts what
  is new unless a status is chosen, and so does a tag, over the feeds `tag_feeds` gives it.
  """
  def tally(rows, filters, tag_feeds \\ %{}) do
    filters = normalize_filters(filters)

    tagged =
      if filters["tag"] == "",
        do: [],
        else: Map.get(tag_feeds, String.to_integer(filters["tag"]), [])

    beside = fn own -> Enum.filter(rows, &matches_except?(&1, filters, own, tagged)) end
    sources = Map.new(rows, &{&1.feed_id, 0})

    # A source and a tag are places of their own, so each counts beside whichever is chosen.
    new_or_chosen =
      beside.([:source, :tag]) |> Enum.filter(&(filters["status"] != "" or :inbox in &1.views))

    by_feed = sum_by(new_or_chosen, :feed_id)
    listed = beside.([:status])

    # An entry may stand in two lists, so each counts its own and all items counts it once.
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

  @doc "Whether the list under `filters` holds the entry, for this account alone."
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
  The ids of every entry a list with `filters` shows, however many it has loaded, as a query to
  use inside another, so that marking a whole list never carries its ids.
  """
  def listed_ids(%User{id: user_id}, filters) do
    user_id
    |> filtered_entries(filters)
    |> exclude(:preload)
    |> exclude(:select)
    |> select([e], e.id)
  end

  @doc "How many entries match `filters`, however many a list has loaded. Searches count this way."
  def count(%User{id: user_id}, filters) do
    user_id
    |> filtered_entries(filters)
    |> exclude(:preload)
    |> exclude(:select)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  @doc "How many items match `filters` altogether, read from their `tally/3`."
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
  Reduces request parameters to the three filters, discarding anything else.

  Written here rather than in the view because the same values reach the database. An unrecognised
  value becomes an empty string, which means no filter, so a hand-edited URL narrows nothing.
  """
  def normalize_filters(params) do
    %{
      "status" => params["status"] |> renamed() |> choice(~w(inbox queue heard)),
      "source" => source_id(params["source"]),
      "tag" => source_id(params["tag"]),
      "q" => search_text(params["q"])
    }
  end

  # What was typed, trimmed and of a length worth asking for.
  defp search_text(text) when is_binary(text), do: text |> String.trim() |> String.slice(0, 100)
  defp search_text(_text), do: ""

  # The lists' names before the inbox, which old addresses and links still carry.
  defp renamed("new"), do: "inbox"
  defp renamed("in_progress"), do: "queue"
  defp renamed("completed"), do: "heard"
  defp renamed(status), do: status

  defp choice(value, values), do: if(value in values, do: value, else: "")

  # Two kinds, by what a reader does with them. The platform names are what links said before.
  defp source_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> Integer.to_string(id)
      _ -> ""
    end
  end

  defp source_id(_), do: ""

  # A source is one feed. A tag gathers the feeds of the account's subscriptions that carry it.
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

        # An entry nobody has opened has no row at all, which is the same thing as new.
        "inbox" ->
          where(query, [e, s, p], (is_nil(p.id) or p.status == :new) and is_nil(p.queue_rank))

        "queue" ->
          where(query, [e, s, p], not is_nil(p.queue_rank))

        "heard" ->
          where(query, [e, s, p], p.status == :heard)
      end

    matching(query, filters["q"])
  end

  # Words a reader remembers, in the title, the notes or the excerpt, as Sikio.Feeds.SearchText
  # stored them: lowercase and without markup. What was typed is text, so the pattern characters
  # in it are escaped, and lowercase too, so case never decides.
  defp matching(query, ""), do: query

  defp matching(query, text), do: where(query, [e], ^containing(String.downcase(text)))

  # A trigram index serves the search on either database. Postgres keeps it on the column, which
  # `LIKE` uses. SQLite keeps it in a full-text table of its own, which uses it for `GLOB` and
  # for `LIKE` without `ESCAPE`, so the search asks that table with `GLOB`. Each pattern language
  # has its own wildcards, and those in what was typed are taken literally.
  if Application.compile_env!(:sikio, :database) == :sqlite do
    defp containing(text) do
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
  else
    defp containing(text) do
      pattern = "%" <> String.replace(text, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
      dynamic([e], fragment("? LIKE ? ESCAPE '\\'", e.search_text, ^pattern))
    end
  end

  # The join to subscriptions is what makes this account-scoped. Every query over entries starts
  # here, including the ownership check on each write.
  defp subscribed_entries(user_id) do
    from e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id
  end

  # The left join carries this account's progress onto the shared row.
  defp scoped_entries(user_id) do
    from [e, s] in subscribed_entries(user_id),
      left_join: p in State,
      on: p.entry_id == e.id and p.user_id == ^user_id,
      join: f in assoc(e, :feed)
  end

  defp entry_query(user_id) do
    from [e, s, p, f] in scoped_entries(user_id),
      select_merge: %{playback: p, source_name: coalesce(s.name, f.title)},
      # Bound to the join above. An unbound `preload: [:feed]` joins and then fetches the feeds a
      # second time, which every library page and every saved position would pay for.
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
  Removes one account's subscription, leaving the shared feed and its entries in place.

  Somebody else may still be subscribed, and this account may subscribe again later and find its
  progress where it left it.
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
  The feeds somebody wants refreshed whose next check has come.

  Every request sets that moment, see `Sikio.Feeds.Schedule`; a feed without one is due at once.
  It is written a moment after the feed was queued, so a minute of leeway keeps the feed from
  waiting one run of the scheduler more.
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

  # An id from a request that is not one finds nothing, rather than raising.
  defp with_id(id, fun) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> fun.(id)
      _ -> nil
    end
  end
end
