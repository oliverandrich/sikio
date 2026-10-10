# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddFeedArtworkCheckedAt do
  use Ecto.Migration

  # When Apple's directory was last asked for a podcast's missing artwork.
  def change do
    alter table(:feeds) do
      add :artwork_checked_at, :utc_datetime_usec
    end
  end
end
