defmodule Sikio.Feeds.Entry do
  @moduledoc "An imported episode or video, independent of each account's progress."
  use Ecto.Schema

  alias Sikio.Feeds.Feed

  schema "entries" do
    belongs_to :feed, Feed
    field :external_id, :string
    field :title, :string
    field :media_url, :string
    field :video_id, :string
    field :published_at, :utc_datetime_usec
    # Filled per account by the queries that join playback state, so a shared row never carries
    # somebody else's progress.
    field :playback, :map, virtual: true
    timestamps(type: :utc_datetime_usec)
  end
end
