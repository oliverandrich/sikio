# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddSubscriptionDelivery do
  use Ecto.Migration

  # The subscriptions table is this application's. A constant default fills existing rows at once.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file check_constraint_added

  @check "delivery IN ('inbox', 'queue', 'skip')"

  # Where a subscription sends what its source publishes next: the inbox, the end of the queue, or
  # straight to the archive. SQLite takes the check with the column, Postgres beside it.
  def change do
    if repo().__adapter__() == Ecto.Adapters.SQLite3 do
      alter table(:subscriptions) do
        add :delivery, :text,
          null: false,
          default: "inbox",
          check: %{name: "valid_delivery", expr: @check}
      end
    else
      alter table(:subscriptions) do
        add :delivery, :text, null: false, default: "inbox"
      end

      create constraint(:subscriptions, :valid_delivery, check: @check)
    end
  end
end
