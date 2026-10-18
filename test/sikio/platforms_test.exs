# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PlatformsTest do
  @moduledoc """
  An administrator switches platforms on or off for the instance. All are on by default.
  """
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Platforms

  defp account(attrs \\ %{}),
    do: Repo.insert!(struct(%User{username: unique_username()}, attrs))

  test "every platform is on by default" do
    assert Platforms.enabled() == %{podcast: true, youtube: true, peertube: true, mediathek: true}
    assert Platforms.enabled?(:youtube)
  end

  test "an administrator switches a platform off and on again" do
    admin = account(%{admin: true})

    assert {:ok, %{youtube: false, podcast: true}} = Platforms.set(admin, :youtube, false)
    refute Platforms.enabled?(:youtube)

    assert {:ok, %{youtube: true}} = Platforms.set(admin, :youtube, true)
    assert Platforms.enabled?(:youtube)
  end

  test "a member switches nothing, and an unknown platform is refused" do
    assert Platforms.set(account(), :youtube, false) == {:error, :forbidden}
    assert Platforms.enabled?(:youtube)
    assert Platforms.set(account(%{admin: true}), :vimeo, false) == {:error, :unknown}
  end

  # Every way into a library runs through `subscribe/3` or `save/4`: the add page, OPML and the
  # library transfer.
  test "a platform that is off takes no new subscription or saved item" do
    admin = account(%{admin: true})
    {:ok, _} = Platforms.set(admin, :youtube, false)
    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, show} = Parser.parse(podcast(), feed_url())

    assert Library.subscribe(admin, video) == {:error, :platform_off}
    [entry | _] = video.entries
    assert Library.save(admin, video, entry.external_id, :inbox) == {:error, :platform_off}
    assert Library.subscriptions(admin) == []

    assert {:ok, _subscription} = Library.subscribe(admin, show)
  end

  # Subscribing again changes nothing, whatever the switch says now.
  test "a source already followed is found again after its platform went off" do
    admin = account(%{admin: true})
    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, subscription} = Library.subscribe(admin, video)
    {:ok, _} = Platforms.set(admin, :youtube, false)

    assert {:ok, %{id: id}} = Library.subscribe(admin, video)
    assert id == subscription.id
  end
end
