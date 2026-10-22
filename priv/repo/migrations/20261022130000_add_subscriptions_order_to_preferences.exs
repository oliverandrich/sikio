# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddSubscriptionsOrderToPreferences do
  use Ecto.Migration

  # The order of the subscriptions page: "name", or "added" for the newest subscription first.
  # Existing rows list by name.
  # The table is this application's. A constant default fills existing rows at once.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  def change do
    alter table(:preferences) do
      add :subscriptions_order, :string, null: false, default: "name"
    end
  end
end
