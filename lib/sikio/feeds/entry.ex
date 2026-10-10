# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Entry do
  @moduledoc "An imported episode or video, shared between accounts and free of playback state."
  use Ecto.Schema

  alias Sikio.Feeds.Feed

  schema "entries" do
    belongs_to :feed, Feed
    field :external_id, :string
    field :title, :string
    field :media_url, :string
    # A PeerTube video's audio-only file. The player offers it instead of the picture.
    field :audio_url, :string
    field :video_id, :string
    # The PeerTube embed URL from the feed. It names the video for the instance's API.
    # It is not built from parts a later release may change.
    field :embed_url, :string
    # The item's page URL from the feed: the episode page, or the video page on its platform.
    field :page_url, :string
    # Chapters as `%{"at" => seconds, "title" => title}`, embedded in the item or loaded on demand
    # from the JSON file at `chapters_url`. Nil until loaded.
    field :chapters, {:array, :map}
    field :chapters_url, :string
    field :published_at, :utc_datetime_usec
    field :image_url, :string
    field :duration, :integer
    # A YouTube Short, as listed in the channel's Shorts feed. Once true, it stays true.
    field :short, :boolean, default: false
    # The publisher's notes, stored unsanitized. They are filtered on output, not on import, so
    # filter improvements apply to existing entries. Podcasts use HTML and YouTube plain text.
    # The source element determines the format.
    field :description, :string
    field :description_format, Ecto.Enum, values: [html: "html", text: "text"]
    field :excerpt, :string
    # The text library search matches; see Sikio.Feeds.SearchText.
    field :search_text, :string
    # Set per account by queries that join playback state. The shared row never stores progress.
    field :playback, :map, virtual: true
    # The account's custom source name, or else the feed title. Set per account with playback,
    # for the same reason.
    field :source_name, :string, virtual: true
    # Whether the account follows the entry's source. False for an entry it saved singly.
    field :followed, :boolean, virtual: true
    timestamps(type: :utc_datetime_usec)
  end
end
