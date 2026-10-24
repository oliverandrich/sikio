# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.FeedAlias do
  @moduledoc """
  Another URL of a feed stored at its self URL. A page or a directory may link the feed there.
  """
  use Ecto.Schema

  alias Sikio.Feeds.Feed

  schema "feed_aliases" do
    belongs_to :feed, Feed
    field :url, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
