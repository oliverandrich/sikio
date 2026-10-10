# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddEntryAudioUrl do
  use Ecto.Migration

  # A PeerTube video's audio-only file. The player offers it as an alternative to the picture.
  def change do
    alter table(:entries) do
      add :audio_url, :text
    end
  end
end
