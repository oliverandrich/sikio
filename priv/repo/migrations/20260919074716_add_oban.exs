defmodule Sikio.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Pinned for the same reason the Ithibati migrations are: an unpinned call installs whichever
  # schema the library has reached by the time it runs, and rolls back to a different one.
  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 1)
end
