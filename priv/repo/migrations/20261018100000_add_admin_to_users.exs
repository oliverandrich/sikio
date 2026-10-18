# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  # The table is this application's. A constant default fills existing rows at once.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # One UPDATE grants the role to the claiming account; Ecto's migration DSL has no word for it.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Removing the column is what reversing this migration means.
  # excellent_migrations:safety-assured-for-this-file column_removed

  # Ithibati records the account that claimed the instance in `ithibati_bootstrap`. Its row
  # keeps no account once that account was deleted, and the instance then has no administrator.
  # The table's name follows Ithibati's `table_prefix`.
  def up do
    alter table(:users) do
      add :admin, :boolean, null: false, default: false
    end

    execute """
    UPDATE users SET admin = TRUE
    WHERE id IN (SELECT user_id FROM #{Ithibati.Config.table("bootstrap")} WHERE user_id IS NOT NULL)
    """
  end

  def down do
    alter table(:users) do
      remove :admin
    end
  end
end
