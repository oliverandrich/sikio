# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateInstanceSettings do
  use Ecto.Migration

  # The instance's one row of settings: which platforms members may add from. The table starts
  # empty, which `Sikio.Platforms` reads as every platform on. The first change writes the row,
  # so a database conversion still finds every copied table empty in its target.
  def change do
    create table(:instance_settings) do
      add :podcast, :boolean, null: false, default: true
      add :youtube, :boolean, null: false, default: true
      add :peertube, :boolean, null: false, default: true
      add :mediathek, :boolean, null: false, default: true
    end
  end
end
