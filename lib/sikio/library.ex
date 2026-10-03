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
  alias Sikio.Feeds.Feed
  alias Sikio.Library.Events
  alias Sikio.Library.Subscription
  alias Sikio.Playback.State
  alias Sikio.Repo

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
        with {:ok, feed} <- Feeds.store(preview),
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
    query = user_id |> filtered_entries(filters) |> behind(opts[:after])

    Repo.all(
      from e in query,
        order_by: [desc_nulls_last: e.published_at, desc: e.id],
        limit: ^Keyword.get(opts, :limit, 100)
    )
  end

  defp behind(query, nil), do: query

  defp behind(query, %{published_at: nil, id: id}),
    do: where(query, [e], is_nil(e.published_at) and e.id < ^id)

  defp behind(query, %{published_at: published_at, id: id}),
    do:
      where(
        query,
        [e],
        e.published_at < ^published_at or (e.published_at == ^published_at and e.id < ^id) or
          is_nil(e.published_at)
      )

  @doc """
  This account's entries grouped by source, medium and status, from one query.

  The rows are what `tally/2` adds up for whichever filters are in force. An entry nobody has
  opened has no progress row and is counted as new.
  """
  def counts(%User{id: user_id}) do
    Repo.all(
      from [e, s, p, f] in scoped_entries(user_id),
        group_by: [e.feed_id, f.kind, p.status],
        select: {e.feed_id, f.kind, p.status, count(e.id)}
    )
    |> Enum.map(fn {feed_id, kind, status, count} ->
      %{feed_id: feed_id, medium: Feed.medium(kind), status: status || :new, count: count}
    end)
  end

  @doc """
  How many items each link in the sidebar shows, under the filters in force.

  Each count honours the filters its link keeps and replaces only its own. A source counts what
  is new unless a status is chosen.
  """
  def tally(rows, filters) do
    filters = normalize_filters(filters)
    beside = fn own -> Enum.filter(rows, &matches_except?(&1, filters, own)) end
    sources = Map.new(rows, &{&1.feed_id, 0})

    new_or_chosen =
      beside.(:source) |> Enum.filter(&(filters["status"] != "" or &1.status == :new))

    %{all: 0, new: 0, in_progress: 0, completed: 0, video: 0, audio: 0}
    |> Map.merge(sum_by(beside.(:status), :status))
    |> Map.merge(sum_by(beside.(:kind), :medium))
    |> Map.update!(:all, fn _ -> beside.(:status) |> Enum.map(& &1.count) |> Enum.sum() end)
    |> Map.put(:sources, Map.merge(sources, sum_by(new_or_chosen, :feed_id)))
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

  @doc "How many items match `filters` altogether, read from their `tally/2`."
  def total(tally, filters) do
    status = normalize_filters(filters)["status"]
    Map.fetch!(tally, if(status == "", do: :all, else: String.to_existing_atom(status)))
  end

  defp sum_by(rows, key) do
    Enum.reduce(rows, %{}, fn row, sums ->
      Map.update(sums, Map.fetch!(row, key), row.count, &(&1 + row.count))
    end)
  end

  defp matches_except?(row, filters, own) do
    Enum.all?([:source, :kind, :status] -- [own], fn
      :source -> filters["source"] in ["", to_string(row.feed_id)]
      :kind -> filters["kind"] in ["", Atom.to_string(row.medium)]
      :status -> filters["status"] in ["", Atom.to_string(row.status)]
    end)
  end

  @doc """
  Reduces request parameters to the three filters, discarding anything else.

  Written here rather than in the view because the same values reach the database. An unrecognised
  value becomes an empty string, which means no filter, so a hand-edited URL narrows nothing.
  """
  def normalize_filters(params) do
    %{
      "kind" => kind(params["kind"]),
      "status" => choice(params["status"], ~w(new in_progress completed)),
      "source" => source_id(params["source"]),
      "q" => search_text(params["q"])
    }
  end

  # What was typed, trimmed and of a length worth asking for.
  defp search_text(text) when is_binary(text), do: text |> String.trim() |> String.slice(0, 100)
  defp search_text(_text), do: ""

  defp choice(value, values), do: if(value in values, do: value, else: "")

  # Two kinds, by what a reader does with them. The platform names are what links said before.
  defp kind(value) when value in ["video", "youtube"], do: "video"
  defp kind(value) when value in ["audio", "podcast"], do: "audio"
  defp kind(_value), do: ""

  defp source_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> Integer.to_string(id)
      _ -> ""
    end
  end

  defp source_id(_), do: ""

  defp filtered_entries(user_id, params) do
    filters = normalize_filters(params)
    query = entry_query(user_id)

    query =
      if filters["source"] == "",
        do: query,
        else: where(query, [e], e.feed_id == ^String.to_integer(filters["source"]))

    query =
      case filters["kind"] do
        "" -> query
        "video" -> where(query, [e, s, p, f], f.kind in ^Feed.video_kinds())
        "audio" -> where(query, [e, s, p, f], f.kind not in ^Feed.video_kinds())
      end

    query =
      case filters["status"] do
        "" -> query
        # An entry nobody has opened has no row at all, which is the same thing as new.
        "new" -> where(query, [e, s, p], is_nil(p.id) or p.status == :new)
        status -> where(query, [e, s, p], p.status == ^status)
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
      select_merge: %{playback: p},
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

  def active_feed_ids do
    Repo.all(from s in Subscription, where: not s.paused, select: s.feed_id, distinct: true)
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
