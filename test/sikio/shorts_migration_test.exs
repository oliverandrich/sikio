# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ShortsMigrationTest do
  @moduledoc """
  The migration that lets a subscription leave out a YouTube channel's Shorts.

  A subscription made before it followed the whole channel and keeps doing so. One made after it
  leaves the Shorts out unless asked. No entry stored before it is known to be a Short.
  """
  use Sikio.MigrationCase

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed

  @before 20_261_007_110_000
  @version 20_261_007_120_000

  test "a subscription made before keeps the Shorts, one made after leaves them out", %{
    repo: repo
  } do
    migrate(repo, :up, @before)

    ada = Repo.insert!(%User{username: "ada"})
    grace = Repo.insert!(%User{username: "grace"})
    feed = Repo.insert!(%Feed{url: "https://example.org/yt", kind: :youtube, title: "F"})
    entry!(feed.id, external_id: "yt:video:abcdefghijk", title: "Old")
    now = DateTime.utc_now()
    row = &%{user_id: &1.id, feed_id: feed.id, inserted_at: now, updated_at: now}
    Repo.insert_all("subscriptions", [row.(ada)])

    migrate(repo, :up, @version)

    Repo.insert_all("subscriptions", [row.(grace)])

    shorts =
      Repo.all(
        from s in "subscriptions", order_by: s.user_id, select: {s.user_id, s.shorts == true}
      )

    assert shorts == [{ada.id, true}, {grace.id, false}]
    assert Repo.all(from e in "entries", select: e.short == true) == [false]
  end
end
