# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateHubSubscriptions do
  use Ecto.Migration

  # A new table, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # A WebSub subscription of a shared feed at its hub. The token names the callback URL, the
  # secret signs what the hub pushes. A row is pending until the hub verifies the callback.
  def change do
    create table(:hub_subscriptions) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :secret, :string, null: false
      add :state, :string, null: false, default: "pending"
      add :requested_at, :utc_datetime_usec
      add :verified_at, :utc_datetime_usec
      add :lease_expires_at, :utc_datetime_usec
      add :renew_at, :utc_datetime_usec
      add :awaiting, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:hub_subscriptions, [:feed_id])
    create unique_index(:hub_subscriptions, [:token])
  end
end
