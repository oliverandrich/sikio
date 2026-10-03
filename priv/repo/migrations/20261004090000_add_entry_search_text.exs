# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddEntrySearchText do
  use Ecto.Migration

  import Ecto.Query

  alias Sikio.Feeds.SearchText

  @moduledoc """
  The text the library's search reads, written on import: title, excerpt and notes, lowercase
  and without markup. Both databases search it alike, which `ILIKE` over stripped HTML was not.

  Stored entries are filled here from their own columns, a thousand at a time. The rule is
  `Sikio.Feeds.SearchText`, so a later change to it applies to new imports only.
  """

  # Removing the column is what reversing this migration means.
  # excellent_migrations:safety-assured-for-this-file column_removed

  @batch 1000

  def up do
    alter table(:entries) do
      add :search_text, :text
    end

    flush()
    fill(0)
  end

  def down do
    alter table(:entries) do
      remove :search_text
    end
  end

  defp fill(after_id) do
    rows =
      repo().all(
        from(e in "entries",
          where: e.id > ^after_id,
          order_by: e.id,
          limit: @batch,
          select: %{
            id: e.id,
            title: e.title,
            excerpt: e.excerpt,
            description: e.description,
            description_format: e.description_format
          }
        )
      )

    for row <- rows do
      repo().update_all(from(e in "entries", where: e.id == ^row.id),
        set: [search_text: SearchText.of(row)]
      )
    end

    if length(rows) == @batch, do: fill(List.last(rows).id)
  end
end
