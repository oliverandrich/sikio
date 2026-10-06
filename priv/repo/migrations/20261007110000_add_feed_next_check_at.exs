# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddFeedNextCheckAt do
  use Ecto.Migration

  # When a feed is asked next. Every request sets it; a feed without one is due at once.
  def change do
    alter table(:feeds) do
      add :next_check_at, :utc_datetime_usec
    end
  end
end
