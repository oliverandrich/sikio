defmodule Sikio.Repo.Migrations.AddPublishedContent do
  use Ecto.Migration

  @moduledoc """
  Room for what feeds already send: artwork, a runtime and the notes beside an item.

  Every column is nullable. A feed imported before this migration keeps its rows and fills them
  on the next poll, because the import replaces the fields it is given.
  """

  def change do
    alter table(:entries) do
      add :image_url, :string, size: 2048
      add :duration, :integer
      add :description, :text
      add :description_format, :string, size: 8
      add :excerpt, :text
    end

    alter table(:feeds) do
      add :icon_url, :string, size: 2048
    end
  end
end
