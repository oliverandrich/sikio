# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateAddressRequests do
  use Ecto.Migration

  # A new table, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # An account's open request to be identified by another address. Each account has at most one.
  # The link holds the token, and the row keeps its digest. A removed account takes it along.
  def change do
    create table(:address_requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :address, :text, null: false
      add :token_digest, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:address_requests, [:user_id])
  end
end
