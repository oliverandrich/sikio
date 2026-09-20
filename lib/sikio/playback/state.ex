# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Playback.State do
  @moduledoc """
  A single account's progress and current playback session for an entry.

  There is no changeset here. Every write goes through `Sikio.Playback`, inside a transaction that
  holds the row, because the values that matter are decided by comparing them with what is already
  stored rather than by validating what arrived.
  """
  use Ecto.Schema

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry

  schema "playback_states" do
    belongs_to :user, User
    belongs_to :entry, Entry
    field :status, Ecto.Enum, values: [:new, :in_progress, :completed], default: :new
    field :position, :float, default: 0.0
    field :duration, :float
    field :completed_at, :utc_datetime_usec
    # The player that owns this entry right now. A second player anywhere takes it over, and the
    # sequence rises with every sample so a late message from the old one cannot win.
    field :session_id, Ecto.UUID
    field :sequence, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
