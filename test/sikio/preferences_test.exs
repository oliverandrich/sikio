# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PreferencesTest do
  @moduledoc """
  Tests an account's preferences: the start page, Play on and the language.
  """
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Preferences
  alias Sikio.Tags

  setup do
    alice = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, alices} = Library.subscribe(alice, preview)
    {:ok, bobs} = Library.subscribe(bob, preview)
    {:ok, [tech]} = Tags.set(alice, alices.id, ["Tech"])
    {:ok, [theirs]} = Tags.set(bob, bobs.id, ["Theirs"])
    %{alice: alice, bob: bob, tech: tech, theirs: theirs}
  end

  # An account without a row starts on the queue, plays on and follows the browser's language.
  test "an account without preferences has the defaults", c do
    assert %{start_view: "queue", start_tag_id: nil, play_on: true, locale: nil} =
             Preferences.get(c.alice)
  end

  test "an account saves its own preferences", c do
    assert {:ok, %{start_view: "inbox", play_on: false, locale: "de"}} =
             Preferences.update(c.alice, %{start_view: "inbox", play_on: false, locale: "de"})

    assert {:ok, %{start_tag_id: tag_id}} =
             Preferences.update(c.alice, %{start_tag_id: c.tech.id})

    assert tag_id == c.tech.id
    assert %{start_view: "inbox", play_on: false, locale: "de"} = Preferences.get(c.alice)
    assert %{start_view: "queue", play_on: true} = Preferences.get(c.bob)
  end

  # A start tag must be one of the account's own tags, and only known values are accepted.
  test "an account cannot choose another account's tag or an unknown value", c do
    assert {:error, changeset} = Preferences.update(c.alice, %{start_tag_id: c.theirs.id})
    assert changeset.errors[:start_tag_id]

    assert {:error, changeset} = Preferences.update(c.alice, %{start_view: "history"})
    assert changeset.errors[:start_view]

    assert {:error, changeset} = Preferences.update(c.alice, %{locale: "fr"})
    assert changeset.errors[:locale]

    assert %{start_view: "queue", start_tag_id: nil, locale: nil} = Preferences.get(c.alice)
  end

  # Clearing the language returns to the browser's.
  test "a blank language follows the browser again", c do
    {:ok, _} = Preferences.update(c.alice, %{locale: "de"})
    assert {:ok, %{locale: nil}} = Preferences.update(c.alice, %{locale: ""})
  end
end
