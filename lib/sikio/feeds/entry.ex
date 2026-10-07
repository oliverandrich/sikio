# SPDX-License-Identifier: AGPL-3.0-or-later

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
    # Where a PeerTube instance plays this video. The feed states it, so nothing here builds
    # an address out of parts a later release may spell differently.
    field :embed_url, :string
    # The item's own page as the feed names it: the episode's, the video's on its platform.
    field :page_url, :string
    # Chapters the feed names, `%{"at" => seconds, "title" => title}`: listed in the item, or read
    # from the JSON file at `chapters_url` once somebody opens the item. Nil until then.
    field :chapters, {:array, :map}
    field :chapters_url, :string
    field :published_at, :utc_datetime_usec
    field :image_url, :string
    field :duration, :integer
    # A YouTube Short, as the channel's Shorts feed names it. Once known, it stays known.
    field :short, :boolean, default: false
    # The publisher's own notes, byte for byte, filtered on the way out rather than on the way
    # in, so a better filter tomorrow applies to what was imported yesterday. A podcast writes
    # markup and YouTube writes plain text, and only the element they came from says which.
    field :description, :string
    field :description_format, Ecto.Enum, values: [html: "html", text: "text"]
    field :excerpt, :string
    # What the library's search reads; see Sikio.Feeds.SearchText.
    field :search_text, :string
    # Filled per account by the queries that join playback state, so a shared row never carries
    # somebody else's progress.
    field :playback, :map, virtual: true
    # The source's name as this account calls it, its own or else the feed's. Filled per account
    # with the progress, for the same reason.
    field :source_name, :string, virtual: true
    timestamps(type: :utc_datetime_usec)
  end
end
