# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddSubscriptionName do
  use Ecto.Migration

  # A name of the account's own for a source, whose feed is shared. Empty, the feed's title stands.
  def change do
    alter table(:subscriptions) do
      add :name, :text
    end
  end
end
