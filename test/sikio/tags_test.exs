# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.TagsTest do
  @moduledoc """
  Tests account-scoped tags on subscriptions. Tags attach to subscriptions, never to shared
  feeds.
  """
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Tags

  setup do
    alice = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, podcast} = Parser.parse(podcast(), feed_url())
    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, podcast_sub} = Library.subscribe(alice, podcast)
    {:ok, video_sub} = Library.subscribe(alice, video)
    {:ok, bobs} = Library.subscribe(bob, podcast)
    %{alice: alice, bob: bob, podcast: podcast_sub, video: video_sub, bobs: bobs}
  end

  defp names(tags), do: Enum.map(tags, & &1.name)

  test "a subscription carries the tags its account gives it, several or none", c do
    assert {:ok, tags} = Tags.set(c.alice, c.podcast.id, ["Tech", " Must view ", ""])
    assert names(tags) == ["Must view", "Tech"]

    # Tag names match case-insensitively.
    assert {:ok, [%{name: "Must view"}]} = Tags.set(c.alice, c.video.id, ["must VIEW"])
    assert names(Tags.list(c.alice)) == ["Must view", "Tech"]
    assert names(Tags.of(c.alice, c.podcast.id)) == ["Must view", "Tech"]

    # Removing a tag from every subscription keeps the tag in `Tags.list/1`.
    assert {:ok, [%{name: "Tech"}]} = Tags.set(c.alice, c.podcast.id, ["Tech"])
    assert {:ok, []} = Tags.set(c.alice, c.video.id, [])
    assert names(Tags.list(c.alice)) == ["Must view", "Tech"]
  end

  test "tags belong to the account that named them", c do
    {:ok, _} = Tags.set(c.alice, c.podcast.id, ["Tech"])

    assert {:error, :not_found} = Tags.set(c.bob, c.podcast.id, ["Mine now"])
    assert Tags.of(c.bob, c.podcast.id) == []
    assert Tags.list(c.bob) == []

    assert {:ok, [bobs]} = Tags.set(c.bob, c.bobs.id, ["Tech"])
    [alices] = Tags.list(c.alice)
    assert bobs.id != alices.id
  end

  # A tag works as a library filter like a feed. It lists and counts the entries of its
  # subscriptions.
  test "a tag lists and counts the entries of its subscriptions", c do
    {:ok, [tech]} = Tags.set(c.alice, c.video.id, ["Tech"])
    tag = to_string(tech.id)

    assert [%{feed: %{kind: :youtube}}] = Library.entries(c.alice, %{"tag" => tag})
    assert Library.count(c.alice, %{"tag" => tag}) == 1
    assert Library.entries(c.bob, %{"tag" => tag}) == []

    counts = Library.tally(Library.counts(c.alice), %{}, Tags.feeds(c.alice))
    assert counts.tags == %{tech.id => 1}

    {:ok, _} = Tags.set(c.alice, c.podcast.id, ["Tech"])
    counts = Library.tally(Library.counts(c.alice), %{}, Tags.feeds(c.alice))
    assert counts.tags == %{tech.id => 2}
  end

  # Renaming keeps the tag id and its subscriptions. A name used by another tag is rejected.
  test "a tag is renamed, but not to a name the account already gives", c do
    {:ok, [tech]} = Tags.set(c.alice, c.podcast.id, ["Tech"])
    {:ok, _} = Tags.set(c.alice, c.video.id, ["Later"])
    Events.subscribe(c.alice)

    assert {:ok, %{id: id, name: "Technik"}} = Tags.rename(c.alice, tech.id, " Technik ")
    assert id == tech.id
    assert_received {:tags_changed, nil}
    assert names(Tags.of(c.alice, c.podcast.id)) == ["Technik"]

    assert {:ok, %{name: "TECHNIK"}} = Tags.rename(c.alice, tech.id, "TECHNIK")
    assert {:error, :taken} = Tags.rename(c.alice, tech.id, "later")
    assert {:error, :blank} = Tags.rename(c.alice, tech.id, "  ")
    assert {:error, :not_found} = Tags.rename(c.bob, tech.id, "Mine")
  end

  # Deleting a tag keeps the subscriptions.
  test "a deleted tag leaves its subscriptions", c do
    {:ok, [tech]} = Tags.set(c.alice, c.podcast.id, ["Tech"])

    assert {:error, :not_found} = Tags.delete(c.bob, tech.id)
    assert {:ok, _} = Tags.delete(c.alice, tech.id)
    assert Tags.list(c.alice) == []
    assert [_, _] = Library.subscriptions(c.alice)
  end

  # Unsubscribing removes the subscription's tag links. The tag itself remains.
  test "unsubscribing takes the tags off, and the tag stays", c do
    {:ok, _} = Tags.set(c.alice, c.podcast.id, ["Tech"])
    {:ok, _} = Library.unsubscribe(c.alice, c.podcast.id)

    assert names(Tags.list(c.alice)) == ["Tech"]
    assert Repo.aggregate(Tags.SubscriptionTag, :count) == 0
  end
end
