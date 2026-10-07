# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Playback.Preference do
  @moduledoc """
  One account's player settings. An account without a row uses the defaults.

  The users table follows Ithibati Starter, so Sikio-specific settings live in a separate table.
  """
  use Ecto.Schema

  alias Sikio.Accounts.User

  schema "playback_preferences" do
    belongs_to :user, User
    # Whether the player continues with the queue when an item ends.
    field :play_on, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end
end
