# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddEntryPageUrl do
  use Ecto.Migration

  @moduledoc """
  Room for an item's own page, which the detail opens.

  `page_url` is nullable. An item imported before this column has none until a poll names it
  again, and a feed may name none at all.
  """

  def change do
    alter table(:entries) do
      add :page_url, :string, size: 2048
    end
  end
end
