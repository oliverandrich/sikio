# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddEntryChapters do
  use Ecto.Migration

  @moduledoc """
  Room for chapters a podcast's feed names: listed in the item, or linked as a JSON file.

  Both columns are nullable. `chapters` is empty until a feed lists some or the linked file is
  fetched, which happens once somebody opens the item. `chapters_url` is that file's address.
  """

  def change do
    alter table(:entries) do
      add :chapters, {:array, :map}
      add :chapters_url, :string, size: 2048
    end
  end
end
