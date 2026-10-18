# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.EntryRemovalTest do
  @moduledoc """
  An administrator removes one entry for everyone. A block by feed and external id keeps a
  refresh from bringing it back, and every account that could see it is told.
  """
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.BlockedEntry
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Removals

  defp account(attrs \\ %{}),
    do: Repo.insert!(struct(%User{username: unique_username()}, attrs))

  # Subscribes the accounts to one podcast feed and returns its only entry.
  defp entry_followed_by(accounts) do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    for account <- accounts, do: {:ok, _} = Library.subscribe(account, preview)
    Repo.one!(from e in Entry, join: f in assoc(e, :feed), where: f.url == ^preview.url)
  end

  test "an administrator removes an entry for everyone, and a refresh keeps it out" do
    admin = account(%{admin: true})
    follower = account()
    entry = entry_followed_by([admin, follower])
    Events.subscribe(follower)

    assert {:ok, %Entry{id: id}} = Removals.remove_entry(admin, entry.id)
    assert id == entry.id
    refute Repo.get(Entry, entry.id)
    assert Repo.get_by(BlockedEntry, feed_id: entry.feed_id, external_id: entry.external_id)
    assert_receive {:entry_removed, ^id}

    # The feed still lists the episode. The refresh imports nothing for it.
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    assert {:ok, _feed} = Feeds.refresh(entry.feed_id)
    assert Repo.all(from e in Entry, where: e.feed_id == ^entry.feed_id) == []
  end

  test "a member removes nothing, and an unknown entry is reported" do
    admin = account(%{admin: true})
    member = account()
    entry = entry_followed_by([member])

    assert Removals.remove_entry(member, entry.id) == {:error, :forbidden}
    assert Repo.get(Entry, entry.id)
    assert Removals.remove_entry(admin, -1) == {:error, :not_found}
  end
end
