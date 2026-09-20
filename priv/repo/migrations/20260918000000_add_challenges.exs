# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddChallenges do
  use Ecto.Migration

  def up, do: Ithibati.Migration.up(from: 1, version: 2)
  def down, do: Ithibati.Migration.down(from: 1, version: 2)
end
