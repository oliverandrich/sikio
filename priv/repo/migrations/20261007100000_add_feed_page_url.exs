# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddFeedPageUrl do
  use Ecto.Migration

  # A source's own website, filled in by the next poll of each feed.
  def change do
    alter table(:feeds) do
      add :page_url, :text
    end
  end
end
