# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddShorts do
  use Ecto.Migration

  # Both tables are this application's. A constant default fills existing rows at once.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # One UPDATE sets every existing subscription; Ecto's migration DSL has no word for it.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Removing the columns is what reversing this migration means.
  # excellent_migrations:safety-assured-for-this-file column_removed

  # Whether an entry is a YouTube Short, and whether a subscription shows them. New subscriptions
  # leave them out. Those made before followed the whole channel and keep doing so.
  def up do
    alter table(:entries) do
      add :short, :boolean, null: false, default: false
    end

    alter table(:subscriptions) do
      add :shorts, :boolean, null: false, default: false
    end

    execute "UPDATE subscriptions SET shorts = TRUE"
  end

  def down do
    alter table(:subscriptions) do
      remove :shorts
    end

    alter table(:entries) do
      remove :short
    end
  end
end
