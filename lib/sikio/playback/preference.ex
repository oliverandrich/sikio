# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Playback.Preference do
  @moduledoc """
  How one account wants the player to behave. An account without a row takes the defaults.

  The users table follows Ithibati Starter, so what belongs to Sikio alone sits beside it.
  """
  use Ecto.Schema

  alias Sikio.Accounts.User

  schema "playback_preferences" do
    belongs_to :user, User
    # Whether the player goes on with the queue when an item ends.
    field :play_on, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end
end
