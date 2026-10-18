# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Removals do
  @moduledoc """
  Shared content an administrator removes for everyone.

  Feeds and entries are shared between accounts, so removing one reaches into every library that
  holds it. Each function takes the acting account first and runs through
  `Sikio.Accounts.with_admin/2`, which reads the role with the administrator rows locked.
  """
  import Ecto.Query

  alias Sikio.Accounts
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Library.Events
  alias Sikio.Library.Favourite
  alias Sikio.Library.SavedEntry
  alias Sikio.Library.Subscription
  alias Sikio.Playback.State
  alias Sikio.Repo

  @doc """
  Returns, for an administrator, how many accounts hold some of the feed and how many entries it
  has: `{:ok, %{members: count, entries: count}}`, for the confirmation.

  An account holds the feed by subscribing, or by a saved entry, a favourite or a playback state
  of one of its entries. Returns `{:error, :forbidden}` unless `admin` is one.
  """
  def feed_removal(admin, feed_id) do
    Accounts.with_admin(admin, fn _admins ->
      entries = Repo.aggregate(from(e in Entry, where: e.feed_id == ^feed_id), :count)
      {:ok, %{members: length(holders(feed_id)), entries: entries}}
    end)
  end

  @doc """
  Removes the feed with `feed_id` for everyone.

  Its subscriptions, entries and every account's playback, favourites, saved entries and tags
  cascade with it. After the commit, every account that held some of it receives
  `{:subscription_removed, feed_id}`, so its open lists reload and its player stops. Adding the
  feed again later stores it afresh. Returns `{:ok, feed}`, `{:error, :not_found}` or
  `{:error, :forbidden}`.
  """
  def remove_feed(admin, feed_id) do
    with {:ok, {feed, holders}} <-
           Accounts.with_admin(admin, fn _admins -> delete_feed(Repo.get(Feed, feed_id)) end) do
      Enum.each(holders, &Events.broadcast(%User{id: &1}, {:subscription_removed, feed.id}))
      {:ok, feed}
    end
  end

  # The holders are read before the cascade takes their rows.
  defp delete_feed(nil), do: {:error, :not_found}

  defp delete_feed(feed) do
    holders = holders(feed.id)
    with {:ok, feed} <- Repo.delete(feed), do: {:ok, {feed, holders}}
  end

  # Every account with a subscription to the feed or a state of one of its entries.
  defp holders(feed_id) do
    entries = from(e in Entry, where: e.feed_id == ^feed_id, select: e.id)
    subscribers = from(s in Subscription, where: s.feed_id == ^feed_id, select: s.user_id)

    [subscribers | Enum.map([SavedEntry, Favourite, State], &holding(&1, entries))]
    |> Enum.flat_map(&Repo.all/1)
    |> Enum.uniq()
  end

  defp holding(schema, entries),
    do: from(r in schema, where: r.entry_id in subquery(entries), select: r.user_id)
end
