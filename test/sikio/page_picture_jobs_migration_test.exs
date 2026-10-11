# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PagePictureJobsMigrationTest do
  @moduledoc """
  Tests the migration that removes the jobs of the retired picture worker.

  Mediathek pictures now come through the picture proxy. Jobs an earlier migration or store
  enqueued name a worker that no longer exists, so they are deleted before Oban runs them.
  """
  use Sikio.MigrationCase

  @before 20_261_011_100_000
  @version 20_261_011_110_000

  test "waiting jobs of the retired worker go, finished ones and others stay", %{repo: repo} do
    migrate(repo, :up, @before)

    job = fn worker, state ->
      %{"n" => 1}
      |> Oban.Job.new(worker: worker, queue: :feeds)
      |> Ecto.Changeset.put_change(:state, state)
      |> Repo.insert!()
    end

    job.("Sikio.Feeds.PagePicture", "available")
    job.("Sikio.Feeds.PagePicture", "retryable")
    job.("Sikio.Feeds.PagePicture", "completed")
    job.("Sikio.Feeds.Refresh", "available")

    migrate(repo, :up, @version)

    assert Repo.all(from j in "oban_jobs", select: {j.worker, j.state}, order_by: j.id) == [
             {"Sikio.Feeds.PagePicture", "completed"},
             {"Sikio.Feeds.Refresh", "available"}
           ]
  end
end
