# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.Transfer do
  @moduledoc """
  Exports an account's library as a document another Sikio instance imports.

  The document carries subscriptions, tags, preferences and the account's entries.
  Entries are referenced by feed URL, external id and page URL, never by database id.
  Feed content stays out, since the target fetches it again.
  Passkeys, recovery codes, sessions and invitations stay out too.
  """

  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Library
  alias Sikio.Library.Favourite
  alias Sikio.Library.SavedEntry
  alias Sikio.Library.Subscription
  alias Sikio.Library.TransferImport
  alias Sikio.Playback
  alias Sikio.Playback.State
  alias Sikio.Preferences
  alias Sikio.Repo
  alias Sikio.Tags

  @version 1

  # An import fetches every feed and may look up entries one by one, so a file stays bounded.
  @max_bytes 5_000_000
  @max_subscriptions 500
  @max_entries 20_000
  # Mediathek ids join a page address and a title, so strings may be longer than an address.
  @max_string 8192
  @max_label 2048

  @doc """
  Returns the account's library as a map ready for JSON encoding.

  An entry is listed when the account follows its source, starred it or saved it singly.
  Archived entries are left out unless starred or saved, since a new subscription archives
  everything its feed already holds. `queue` numbers the queue from 1.
  """
  def export(%User{} = account) do
    %{
      format: "sikio-account",
      version: @version,
      preferences: preferences(account),
      subscriptions: subscriptions(account),
      entries: entries(account)
    }
  end

  defp preferences(account) do
    preference = account |> Preferences.get() |> Repo.preload(:start_tag)

    %{
      play_on: preference.play_on,
      start_view: preference.start_view,
      start_tag: preference.start_tag && preference.start_tag.name,
      locale: preference.locale
    }
  end

  defp subscriptions(account) do
    names = Map.new(Tags.list(account), &{&1.id, &1.name})

    tags =
      for {tag, feeds} <- Tags.feeds(account), feed <- feeds, reduce: %{} do
        tags -> Map.update(tags, feed, [names[tag]], &[names[tag] | &1])
      end

    for subscription <- Library.subscriptions(account) do
      %{
        url: subscription.feed.url,
        kind: subscription.feed.kind,
        title: label(subscription.feed.title),
        name: label(subscription.name),
        paused: subscription.paused,
        delivery: subscription.delivery,
        shorts: subscription.shorts,
        tags: tags |> Map.get(subscription.feed_id, []) |> Enum.sort()
      }
    end
  end

  defp entries(%User{id: user_id} = account) do
    rows =
      Repo.all(
        from e in Entry,
          join: f in Feed,
          on: f.id == e.feed_id,
          left_join: p in State,
          on: p.entry_id == e.id and p.user_id == ^user_id,
          left_join: v in Favourite,
          on: v.entry_id == e.id and v.user_id == ^user_id,
          left_join: c in SavedEntry,
          on: c.entry_id == e.id and c.user_id == ^user_id,
          where: e.id in subquery(Library.visible_entry_ids(account)),
          where: is_nil(p.id) or p.status != :archived or not is_nil(v.id) or not is_nil(c.id),
          order_by: [f.url, e.external_id],
          select: %{
            id: e.id,
            feed_url: f.url,
            external_id: e.external_id,
            page_url: e.page_url,
            title: e.title,
            status: p.status,
            position: p.position,
            duration: p.duration,
            completed_at: p.completed_at,
            rank: p.queue_rank,
            favourite: v.id,
            saved: c.id
          }
      )

    queue =
      rows
      |> Enum.reject(&is_nil(&1.rank))
      |> Enum.sort_by(&{&1.rank, &1.id})
      |> Enum.with_index(1)
      |> Map.new(fn {row, index} -> {row.id, index} end)

    for row <- rows, byte_size(row.external_id) <= @max_string do
      row
      |> Map.drop([:id, :rank])
      |> Map.merge(%{
        title: label(row.title),
        # An entry without a playback row is new.
        status: row.status || :new,
        queue: queue[row.id],
        favourite: not is_nil(row.favourite),
        saved: not is_nil(row.saved)
      })
    end
  end

  # Titles and names inform the reader. Cut at a character boundary, they stay valid UTF-8.
  defp label(nil), do: nil
  defp label(text) when byte_size(text) <= @max_label, do: text

  defp label(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, cut ->
      if byte_size(cut) + byte_size(grapheme) <= @max_label,
        do: {:cont, cut <> grapheme},
        else: {:halt, cut}
    end)
  end

  @doc """
  Checks `json` and imports it for the account in the background, see `TransferImport`.

  Returns `{:ok, job}`, the reason `parse/1` gives, or `{:error, :already_running}` while the
  account's previous import waits or runs.
  """
  def start(%User{id: user_id}, json) do
    with {:ok, _document} <- parse(json) do
      case Oban.insert(TransferImport.new(%{user_id: user_id, document: json})) do
        {:ok, %Oban.Job{conflict?: true}} -> {:error, :already_running}
        result -> result
      end
    end
  end

  @doc """
  Adds the library in a parsed `document` to the account and returns a summary.

  Existing subscriptions keep their settings and gain the document's tags. A new subscription
  receives none of its feed's present entries except those the document lists. States apply
  only to entries without one, except in feeds this call subscribed to. Imported queue entries
  join the end of the queue. Preferences apply only when the account has none stored.

  Every entry comes from its source, never from the document. An entry its feed no longer
  holds is looked up through its page when it is queued, in progress, starred or saved.
  Other entries the feed no longer holds count as missing.
  """
  def restore(%User{} = account, document) do
    known = Map.new(Library.subscriptions(account), &{&1.feed.url, &1})
    fetched = fetch(urls(document, known))
    {subscribed, fresh, summary} = subscribe_all(account, document.subscriptions, known, fetched)
    followed = known |> Map.new(fn {url, s} -> {url, s.feed_id} end) |> Map.merge(subscribed)
    feed_ids = Map.merge(store_chosen(document.entries, followed, fetched), followed)
    {found, missing} = resolve(document.entries, feed_ids, fresh)
    written = write(account, found, MapSet.new(Map.values(followed)))
    restore_preferences(account, document.preferences)

    %{
      subscriptions: summary,
      entries: %{restored: written, kept: length(found) - written, missing: missing}
    }
  end

  # The document's new sources, and the sources of starred or saved entries nobody follows here.
  defp urls(document, known) do
    listed = Map.new(document.subscriptions, &{&1.url, true})

    (Enum.map(document.subscriptions, & &1.url) ++ chosen_sources(document.entries, listed))
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(known, &1))
  end

  # The sources of starred or saved entries outside `followed`, a map keyed by feed URL.
  defp chosen_sources(entries, followed) do
    for entry <- entries,
        entry.favourite or entry.saved,
        not Map.has_key?(followed, entry.feed_url),
        uniq: true,
        do: entry.feed_url
  end

  # Fetches up to five sources concurrently, as the OPML import does.
  # A source whose fetch crashed counts as unavailable, like one whose server is down.
  defp fetch(urls) do
    urls
    |> Task.async_stream(&Discovery.fetch/1, max_concurrency: 5, timeout: :infinity)
    |> Enum.zip_with(urls, fn
      {:ok, result}, url -> {url, result}
      {:exit, _reason}, url -> {url, {:error, :unavailable}}
    end)
    |> Map.new()
  end

  # Returns `%{url => feed_id}`, the ids of feeds this call subscribed to, and the summary.
  defp subscribe_all(account, subscriptions, known, fetched) do
    ids = MapSet.new(Map.values(known), & &1.id)
    initial = {%{}, MapSet.new(), %{imported: 0, existing: 0, failed: []}}

    {subscribed, fresh, summary} =
      Enum.reduce(subscriptions, initial, fn source, acc ->
        tally(
          acc,
          source,
          subscribe_one(account, source, known[source.url], fetched[source.url], ids)
        )
      end)

    {subscribed, fresh, Map.update!(summary, :failed, &Enum.reverse/1)}
  end

  # Both the URL in the file and the feed's stored URL map to the subscription, as in OPML.
  defp tally({subscribed, fresh, summary}, source, {status, subscription}) do
    id = subscription.feed_id
    fresh = if status == :imported, do: MapSet.put(fresh, id), else: fresh

    {subscribed |> Map.put(source.url, id) |> Map.put(subscription.feed.url, id), fresh,
     Map.update!(summary, status, &(&1 + 1))}
  end

  defp tally({subscribed, fresh, summary}, source, :error),
    do: {subscribed, fresh, Map.update!(summary, :failed, &[source.url | &1])}

  defp subscribe_one(account, source, %Subscription{} = subscription, _fetched, _ids),
    do: keep(account, subscription, source)

  # The document's address may lead to a feed the account follows under its final address.
  # Subscribing then returns that subscription, which keeps its settings.
  defp subscribe_one(account, source, nil, {:ok, preview}, ids) do
    case Library.subscribe(account, preview, existing: :none, delivery: source.delivery) do
      {:ok, subscription} ->
        if MapSet.member?(ids, subscription.id),
          do: keep(account, subscription, source),
          else: configure(account, subscription, source)

      _error ->
        :error
    end
  end

  defp subscribe_one(_account, _source, nil, _failed, _ids), do: :error

  # An existing subscription keeps its settings and gains the document's tags.
  defp keep(account, subscription, source) do
    if source.tags != [], do: Tags.add(account, subscription.id, source.tags)
    {:existing, subscription}
  end

  defp configure(account, subscription, source) do
    settings = %{name: source.name, delivery: source.delivery, shorts: source.shorts}

    with {:ok, _} <- Library.configure(account, subscription.id, settings, source.tags),
         {:ok, _} <- paused(account, subscription, source.paused) do
      {:imported, subscription}
    else
      _error -> :error
    end
  end

  defp paused(account, subscription, true), do: Library.pause(account, subscription.id, true)
  defp paused(_account, subscription, false), do: {:ok, subscription}

  # Stores the sources of starred or saved entries nobody follows here, as saving one does.
  defp store_chosen(entries, followed, fetched) do
    entries
    |> chosen_sources(followed)
    |> Enum.flat_map(fn url ->
      with {:ok, preview} <- fetched[url],
           {:ok, feed} <- Feeds.store(preview, &Library.deliver/2) do
        [{url, feed.id}]
      else
        _error -> []
      end
    end)
    |> Map.new()
  end

  # Returns the found entries, each with `entry_id`, `feed_id` and `replace`, and a missing count.
  # An entry in a feed this call subscribed to replaces the state the subscription archived.
  defp resolve(entries, feed_ids, fresh) do
    present = present(entries, feed_ids)
    {found, absent} = Enum.split_with(entries, &present[{feed_ids[&1.feed_url], &1.external_id}])

    found =
      for entry <- found do
        feed_id = feed_ids[entry.feed_url]
        located(entry, present[{feed_id, entry.external_id}], feed_id, feed_id in fresh)
      end

    recovered = absent |> Enum.filter(&(wanted?(&1) and is_binary(&1.page_url))) |> look_up(fresh)
    {found ++ recovered, length(absent) - length(recovered)}
  end

  defp located(entry, id, feed_id, replace),
    do: Map.merge(entry, %{entry_id: id, feed_id: feed_id, replace: replace})

  defp present(entries, feed_ids) do
    entries
    |> Enum.filter(&feed_ids[&1.feed_url])
    |> Enum.group_by(&feed_ids[&1.feed_url], & &1.external_id)
    |> Enum.flat_map(fn {feed_id, external_ids} ->
      external_ids
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn chunk ->
        Repo.all(
          from e in Entry,
            where: e.feed_id == ^feed_id and e.external_id in ^chunk,
            select: {{e.feed_id, e.external_id}, e.id}
        )
      end)
    end)
    |> Map.new()
  end

  defp wanted?(entry),
    do: entry.queue != nil or entry.status == :in_progress or entry.favourite or entry.saved

  # Builds each entry from its page, as adding a single item does. An entry this call created,
  # or one in a feed it subscribed to, replaces the state its feed's delivery may have given it.
  defp look_up(entries, fresh) do
    entries
    |> Task.async_stream(&{&1, item(&1.page_url)}, max_concurrency: 5, timeout: :infinity)
    |> Enum.flat_map(fn
      {:ok, {entry, {:ok, id, feed_id, created}}} ->
        [located(entry, id, feed_id, created or feed_id in fresh)]

      _failed ->
        []
    end)
  end

  defp item(url) do
    with {:ok, %{preview: preview, external_id: external_id}} <- Discovery.item(url),
         held = held?(preview.url, external_id),
         {:ok, feed} <- Feeds.store(preview, &Library.deliver/2),
         %Entry{id: id} <- Repo.get_by(Entry, feed_id: feed.id, external_id: external_id) do
      {:ok, id, feed.id, not held}
    else
      _error -> :error
    end
  end

  defp held?(feed_url, external_id),
    do:
      Repo.exists?(
        from e in Entry,
          join: f in Feed,
          on: f.id == e.feed_id,
          where: f.url == ^feed_url and e.external_id == ^external_id
      )

  # An entry outside the followed feeds stays visible through its star or its save.
  # Returns the number of states written.
  defp write(%User{id: user_id} = account, found, followed) do
    now = DateTime.utc_now()
    row = &%{user_id: user_id, entry_id: &1.entry_id, inserted_at: now}
    unseen? = &(not &1.favourite and not MapSet.member?(followed, &1.feed_id))

    insert_chunks(Favourite, for(entry <- found, entry.favourite, do: row.(entry)))

    insert_chunks(
      SavedEntry,
      for(entry <- found, entry.saved or unseen?.(entry), do: row.(entry))
    )

    fields = ~w(entry_id status position duration completed_at queue replace)a
    {:ok, written} = Playback.restore(account, Enum.map(found, &Map.take(&1, fields)))
    written
  end

  # Batches stay below SQLite's limit of bound parameters per statement.
  defp insert_chunks(schema, rows),
    do:
      rows
      |> Enum.chunk_every(500)
      |> Enum.each(&Repo.insert_all(schema, &1, on_conflict: :nothing))

  defp restore_preferences(account, preferences) do
    unless Preferences.stored?(account) do
      tag = Enum.find(Tags.list(account), &(&1.name == preferences.start_tag))

      Preferences.update(account, %{
        play_on: preferences.play_on,
        start_view: preferences.start_view,
        start_tag_id: tag && tag.id,
        locale: preferences.locale
      })
    end
  end

  @doc """
  Reads an exported document. Returns `{:ok, document}` in the shape `export/1` returns.

  One invalid value refuses the whole file, so an import never applies half of it.
  Returns `{:error, reason}` for a file over 5 MB, another format or version, malformed JSON,
  more than 500 subscriptions or more than 20000 entries.
  """
  def parse(json) when is_binary(json) and byte_size(json) > @max_bytes, do: {:error, :too_large}

  def parse(json) when is_binary(json) do
    with {:ok, %{"format" => "sikio-account", "version" => version} = map} <- Jason.decode(json),
         :ok <- supported(version),
         :ok <- within(map["subscriptions"], @max_subscriptions, :too_many_subscriptions),
         :ok <- within(map["entries"], @max_entries, :too_many_entries) do
      {:ok,
       %{
         format: "sikio-account",
         version: version,
         preferences: preferences!(map["preferences"]),
         subscriptions: Enum.map(map["subscriptions"], &subscription!/1),
         entries: Enum.map(map["entries"], &entry!/1)
       }}
    else
      {:error, reason} when is_atom(reason) or is_tuple(reason) -> {:error, reason}
      _ -> {:error, :invalid_document}
    end
  catch
    :invalid -> {:error, :invalid_document}
  end

  defp supported(@version), do: :ok
  defp supported(version), do: {:error, {:unsupported_version, version}}

  defp within(list, max, _reason) when is_list(list) and length(list) <= max, do: :ok
  defp within(list, _max, reason) when is_list(list), do: {:error, reason}
  defp within(_value, _max, _reason), do: {:error, :invalid_document}

  defp preferences!(%{} = map) do
    %{
      play_on: boolean!(map["play_on"]),
      start_view: string!(map["start_view"]),
      start_tag: optional(map["start_tag"], &string!/1),
      locale: optional(map["locale"], &string!/1)
    }
  end

  defp preferences!(_value), do: throw(:invalid)

  defp subscription!(%{} = map) do
    %{
      url: string!(map["url"]),
      kind: optional(map["kind"], &one_of!(&1, Ecto.Enum.values(Feed, :kind))),
      title: optional(map["title"], &string!/1),
      name: optional(map["name"], &string!/1),
      paused: boolean!(map["paused"]),
      delivery: one_of!(map["delivery"], Ecto.Enum.values(Subscription, :delivery)),
      shorts: boolean!(map["shorts"]),
      tags: list!(map["tags"], &string!/1)
    }
  end

  defp subscription!(_value), do: throw(:invalid)

  defp entry!(%{} = map) do
    %{
      feed_url: string!(map["feed_url"]),
      external_id: string!(map["external_id"]),
      page_url: optional(map["page_url"], &string!/1),
      title: optional(map["title"], &string!/1),
      status: one_of!(map["status"], Ecto.Enum.values(State, :status)),
      position: optional(map["position"], &seconds!/1),
      duration: optional(map["duration"], &seconds!/1),
      completed_at: optional(map["completed_at"], &datetime!/1),
      queue: optional(map["queue"], &rank!/1),
      favourite: boolean!(map["favourite"]),
      saved: boolean!(map["saved"])
    }
  end

  defp entry!(_value), do: throw(:invalid)

  defp optional(nil, _check), do: nil
  defp optional(value, check), do: check.(value)

  defp string!(value) when is_binary(value) and byte_size(value) <= @max_string, do: value
  defp string!(_value), do: throw(:invalid)

  defp boolean!(value) when is_boolean(value), do: value
  defp boolean!(_value), do: throw(:invalid)

  defp seconds!(value) when is_number(value) and value >= 0, do: value / 1
  defp seconds!(_value), do: throw(:invalid)

  defp rank!(value) when is_integer(value) and value > 0, do: value
  defp rank!(_value), do: throw(:invalid)

  defp list!(values, check) when is_list(values), do: Enum.map(values, check)
  defp list!(_values, _check), do: throw(:invalid)

  defp one_of!(value, atoms) when is_binary(value),
    do: Enum.find(atoms, &(Atom.to_string(&1) == value)) || throw(:invalid)

  defp one_of!(_value, _atoms), do: throw(:invalid)

  defp datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> throw(:invalid)
    end
  end

  defp datetime!(_value), do: throw(:invalid)
end
