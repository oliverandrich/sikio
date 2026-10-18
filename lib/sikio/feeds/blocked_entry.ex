# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.BlockedEntry do
  @moduledoc """
  An entry an administrator removed for everyone. The import skips its external id in its feed.
  """
  use Ecto.Schema

  alias Sikio.Feeds.Feed

  schema "blocked_entries" do
    belongs_to :feed, Feed
    field :external_id, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
