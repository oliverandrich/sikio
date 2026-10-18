# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.FeedRemovalTest do
  @moduledoc """
  An administrator removes a feed for everyone. Its subscriptions, entries and every account's
  states go with it, and every account that held some of it is told.
  """
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Library.Favourite
  alias Sikio.Library.SavedEntry
  alias Sikio.Library.Subscription
  alias Sikio.Removals

  defp account(attrs \\ %{}),
    do: Repo.insert!(struct(%User{username: unique_username()}, attrs))

  # Subscribes the followers to one podcast feed, and saves its episode for the savers, who do
  # not follow it. Returns the feed's id and its entry.
  defp held_by(followers, savers \\ []) do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    for account <- followers, do: {:ok, _} = Library.subscribe(account, preview)
    [episode] = preview.entries

    for account <- savers,
        do: {:ok, _} = Library.save(account, preview, episode.external_id, :inbox)

    feed = Repo.get_by!(Feed, url: preview.url)
    {feed.id, Repo.get_by!(Entry, feed_id: feed.id)}
  end

  # The dialog counts every account that loses something, not only the followers.
  test "an administrator learns how many members and entries the removal reaches" do
    admin = account(%{admin: true})
    {feed_id, _entry} = held_by([admin, account()], [account()])

    assert Removals.feed_removal(admin, feed_id) == {:ok, %{members: 3, entries: 1}}
    assert Removals.feed_removal(account(), feed_id) == {:error, :forbidden}
  end

  test "an administrator removes a feed with everything that hangs on it" do
    admin = account(%{admin: true})
    follower = account()
    saver = account()
    {feed_id, entry} = held_by([admin, follower], [saver])
    {:ok, _} = Library.favourite(follower, entry.id, true)
    Events.subscribe(saver)

    assert {:ok, %Feed{id: ^feed_id}} = Removals.remove_feed(admin, feed_id)

    refute Repo.get(Feed, feed_id)
    assert Repo.all(from e in Entry, where: e.feed_id == ^feed_id) == []
    assert Repo.all(from s in Subscription, where: s.feed_id == ^feed_id) == []
    assert Repo.all(from s in SavedEntry, where: s.entry_id == ^entry.id) == []
    assert Repo.all(from f in Favourite, where: f.entry_id == ^entry.id) == []
    # A saver follows nothing, yet their open lists and player learn of it.
    assert_receive {:subscription_removed, ^feed_id}
  end

  test "a member removes nothing, and an unknown feed is reported" do
    admin = account(%{admin: true})
    member = account()
    {feed_id, _entry} = held_by([member])

    assert Removals.remove_feed(member, feed_id) == {:error, :forbidden}
    assert Repo.get(Feed, feed_id)
    assert Removals.remove_feed(admin, -1) == {:error, :not_found}
  end
end
