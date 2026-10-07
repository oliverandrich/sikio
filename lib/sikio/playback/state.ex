# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Playback.State do
  @moduledoc """
  One account's progress and current playback session for an entry.

  This schema has no changeset. Every write goes through `Sikio.Playback` in a transaction that
  locks the row. Each write derives its values from the stored row, not from input validation.
  """
  use Ecto.Schema

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry

  schema "playback_states" do
    belongs_to :user, User
    belongs_to :entry, Entry
    # `:new` until played or archived. `:heard` at 90 % or when marked.
    # `:archived` when set aside.
    field :status, Ecto.Enum, values: [:new, :in_progress, :heard, :archived], default: :new
    field :position, :float, default: 0.0
    field :duration, :float
    # When the entry was heard or archived. The history sorts by it.
    field :completed_at, :utc_datetime_usec
    # The queue position, ascending, or nil when not queued.
    field :queue_rank, :float
    # The session of the player that owns this entry. Starting another player replaces it.
    # The sequence increases with every sample, so a late sample from the old session fails.
    field :session_id, Ecto.UUID
    field :sequence, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
