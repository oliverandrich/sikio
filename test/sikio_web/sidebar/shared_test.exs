# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar.SharedTest do
  @moduledoc false
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo
  alias SikioWeb.Sidebar.Shared

  setup do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, podcast} = Parser.parse(podcast(), feed_url())
    {:ok, sub} = Library.subscribe(user, podcast)
    [entry] = Library.entries(user)
    %{user: user, sub: sub, entry: entry}
  end

  # Every open page asks after the same change. A load that started after a page saw the change
  # already holds it, so the pages share one load.
  test "serves pages from a load that started after they saw the change", c do
    seen = System.monotonic_time()
    {first, _} = Shared.fetch(c.user, seen, :library_changed)

    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(c.user, video)

    assert {^first, _} = Shared.fetch(c.user, seen, :library_changed)

    {fresh, _} = Shared.fetch(c.user, System.monotonic_time(), :library_changed)
    assert length(fresh.sources) == length(first.sources) + 1
  end

  # A page showing one source or tag rereads its list only for changes to its feeds.
  test "names the feeds an event reaches", c do
    now = System.monotonic_time()
    feed = c.sub.feed_id
    state = %Playback.State{entry_id: c.entry.id, user_id: c.user.id, status: :heard}

    assert {_, [^feed]} = Shared.fetch(c.user, now, {:playback_changed, state})
    assert {_, [^feed]} = Shared.fetch(c.user, now, {:entry_saved, c.entry.id})
    assert {_, [^feed]} = Shared.fetch(c.user, now, {:entry_removed, c.entry.id})
    assert {_, [^feed]} = Shared.fetch(c.user, now, {:favourite_changed, c.entry.id})
    assert {_, :all} = Shared.fetch(c.user, now, {:subscription_removed, feed})
    assert {_, :all} = Shared.fetch(c.user, now, {:tags_changed, nil})
    assert {_, :all} = Shared.fetch(c.user, now, :library_changed)
  end
end
