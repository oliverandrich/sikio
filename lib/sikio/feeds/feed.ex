# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Feed do
  @moduledoc "A feed shared between accounts. Per-account membership lives in subscriptions."
  use Ecto.Schema

  import Ecto.Changeset

  schema "feeds" do
    field :url, :string
    field :title, :string
    field :kind, Ecto.Enum, values: [:youtube, :podcast, :peertube]
    field :icon_url, :string
    field :page_url, :string
    field :etag, :string
    field :last_modified, :string
    field :last_checked_at, :utc_datetime_usec
    field :last_error, :string
    field :next_check_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :url,
      :title,
      :kind,
      :icon_url,
      :page_url,
      :etag,
      :last_modified,
      :last_checked_at,
      :last_error
    ])
    |> validate_required([:url, :title, :kind])
    |> validate_length(:title, max: 512)
    |> unique_constraint(:url)
  end

  @doc "Returns the channel id of a whole YouTube channel feed, or nil. Only those have Shorts."
  def channel_id(%{kind: :youtube, url: url}) do
    query = URI.parse(url).query || ""
    URI.decode_query(query)["channel_id"]
  end

  def channel_id(_feed), do: nil

  @doc "Returns whether a feed follows a whole YouTube channel."
  def channel?(feed), do: channel_id(feed) != nil
end
