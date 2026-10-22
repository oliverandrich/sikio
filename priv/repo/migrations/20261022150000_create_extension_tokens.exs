# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateExtensionTokens do
  use Ecto.Migration

  # New tables, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # A connected browser extension's token, and the one-time codes that lead to one. Each row
  # keeps a digest; only the extension holds the token or the code. A removed account takes both.
  def change do
    create table(:extension_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_digest, :binary, null: false
      add :label, :text, null: false
      add :last_used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:extension_tokens, [:token_digest])
    create index(:extension_tokens, [:user_id])

    create table(:extension_grants) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :code_digest, :binary, null: false
      add :code_challenge, :text, null: false
      add :redirect_uri, :text, null: false
      add :label, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:extension_grants, [:code_digest])
  end
end
