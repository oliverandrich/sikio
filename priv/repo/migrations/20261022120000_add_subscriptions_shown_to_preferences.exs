# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddSubscriptionsShownToPreferences do
  use Ecto.Migration

  # Which subscriptions the sidebar and the phone's list show: "all", or "new" for those with
  # unfinished items. Existing rows keep showing all.
  # The table is this application's. A constant default fills existing rows at once.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  def change do
    alter table(:preferences) do
      add :subscriptions_shown, :string, null: false, default: "all"
    end
  end
end
