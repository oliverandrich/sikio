# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.OpenInvitations do
  use Ecto.Migration

  # Ithibati's schema version 5 lets an invitation leave the name to the invitee. The table was
  # created earlier, so it opens in a migration of its own. On SQLite this rebuilds the table.
  # `up/1` then checks the table at version 5.
  def up do
    Ithibati.Migration.open_invitations(version: 5)
    Ithibati.Migration.up(from: 3, version: 5)
  end

  def down do
    Ithibati.Migration.down(from: 3, version: 5)
    Ithibati.Migration.open_invitations(version: 5)
  end
end
