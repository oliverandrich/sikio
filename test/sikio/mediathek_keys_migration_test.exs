# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.MediathekKeysMigrationTest do
  @moduledoc """
  Tests the migration that keys Mediathek programmes by their broadcaster's page.

  MediathekViewWeb lists geo-blocked copies and can change its ids, so stored programmes hold
  copies. The migration merges them into the open copy, with the account's furthest state.
  Programmes without a picture ask their broadcaster's page for one.
  """
  use Sikio.MigrationCase

  alias Sikio.Feeds.Feed

  @before 20_261_011_090_000
  @version 20_261_011_100_000

  test "copies of one page become the open one, with the furthest state", %{repo: repo} do
    migrate(repo, :up, @before)

    user = user!("ada")
    url = "https://mediathekviewweb.de/feed?query=x"
    series = Repo.insert!(%Feed{url: url, kind: :mediathek, title: "House of Yang · SWR"})
    podcast = Repo.insert!(%Feed{url: "https://example.org/rss", kind: :podcast, title: "P"})
    page = "https://www.ardmediathek.de/video/yang-1"

    programme = fn external_id, attrs ->
      entry!(
        series.id,
        [external_id: external_id, title: "Folge 1", media_url: "https://swr.example/v.mp4"] ++
          attrs
      )
    end

    geo = programme.("a1=", page_url: page, media_url: "https://swr.example/geo/de-at-ch/v.mp4")
    open = programme.("a2=", page_url: page)
    later = programme.("a3=", page_url: page)
    other = programme.("b1=", page_url: "https://www.ardmediathek.de/video/yang-2")
    # Another programme on the same page, and a copy without a media address.
    part = programme.("e1=", page_url: page, title: "Folge 1, Teil 2")

    silent =
      programme.("f1=", page_url: "https://www.ardmediathek.de/video/yang-4", media_url: nil)

    pictured =
      programme.("d1=",
        page_url: "https://www.ardmediathek.de/video/yang-3",
        image_url: "https://img.example/3.jpg"
      )

    bare = programme.("c1=", [])

    unrelated =
      entry!(podcast.id, external_id: "p1", title: "P", media_url: "https://p.example/1.mp3")

    now = DateTime.utc_now()

    state = fn entry, status, position ->
      %{
        user_id: user.id,
        entry_id: entry.id,
        status: status,
        position: position,
        queue_rank: nil,
        inserted_at: now,
        updated_at: now
      }
    end

    # The furthest state wins. A queue place survives the merge.
    queued = Map.put(state.(later, "new", 0), :queue_rank, 2.0)

    Repo.insert_all("playback_states", [
      state.(geo, "heard", 0),
      state.(open, "archived", 0),
      queued
    ])

    Repo.insert_all("saved_entries", [
      %{user_id: user.id, entry_id: later.id, inserted_at: now}
    ])

    migrate(repo, :up, @version)

    stored =
      Repo.all(
        from e in "entries",
          where: e.feed_id == ^series.id,
          order_by: e.id,
          select: {e.id, e.external_id}
      )

    assert stored == [
             {open.id, page <> " Folge 1"},
             {other.id, "https://www.ardmediathek.de/video/yang-2 Folge 1"},
             {part.id, page <> " Folge 1, Teil 2"},
             {silent.id, "https://www.ardmediathek.de/video/yang-4 Folge 1"},
             {pictured.id, "https://www.ardmediathek.de/video/yang-3 Folge 1"},
             {bare.id, "c1="}
           ]

    assert [{id, "heard", rank}] =
             Repo.all(
               from p in "playback_states",
                 select: {p.entry_id, p.status, p.queue_rank},
                 where: p.user_id == ^user.id
             )

    assert id == open.id
    assert rank == 2 or rank == Decimal.new("2.0") or rank == 2.0

    assert Repo.all(from s in "saved_entries", select: s.entry_id) == [open.id]
    assert Repo.exists?(from e in "entries", where: e.id == ^unrelated.id)

    assert [%{"feed_id" => feed_id, "entry_ids" => ids}] =
             Repo.all(
               from j in "oban_jobs",
                 where: j.worker == "Sikio.Feeds.PagePicture",
                 select: j.args
             )
             |> Enum.map(&decoded/1)

    # Oban runs the job as one it enqueued itself.
    assert [{"available", "feeds", 5, at}] =
             Repo.all(
               from j in "oban_jobs",
                 where: j.worker == "Sikio.Feeds.PagePicture",
                 select: {j.state, j.queue, j.priority, j.scheduled_at}
             )

    refute is_nil(at)
    assert feed_id == series.id
    assert Enum.sort(ids) == Enum.sort([open.id, other.id, part.id, silent.id])
  end

  # SQLite returns the JSON column as text.
  defp decoded(args) when is_binary(args), do: Jason.decode!(args)
  defp decoded(args), do: args
end
