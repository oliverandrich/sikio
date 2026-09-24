# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddInvitedBy do
  use Ecto.Migration

  # This table was created before Ithibati's schema version 4, so the inviter arrives in a
  # migration of its own. `ithibati_invitation/0` declares the column, which means every
  # invitation query asks for it; the migration that made the table has already run and will not
  # run again, so nothing but this puts it there. Never edit the one that made the table.
  def change do
    alter table(:invitations) do
      Ithibati.Migration.invitation_inviter_column(version: 4)
    end
  end
end
