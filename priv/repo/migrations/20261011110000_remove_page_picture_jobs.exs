# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.RemovePagePictureJobs do
  use Ecto.Migration

  import Ecto.Query

  @moduledoc """
  Removes waiting jobs of the retired `Sikio.Feeds.PagePicture` worker.

  Mediathek pictures now come through the picture proxy, which asks the broadcaster's page when
  a picture is shown. Oban would fail the jobs that name the missing worker. Finished jobs stay,
  since Oban prunes them. The jobs cannot come back, so a rollback changes nothing.
  """

  def up do
    repo().delete_all(
      from(j in "oban_jobs",
        where: j.worker == "Sikio.Feeds.PagePicture",
        where: j.state in ["available", "scheduled", "retryable", "executing"]
      )
    )
  end

  def down, do: :ok
end
