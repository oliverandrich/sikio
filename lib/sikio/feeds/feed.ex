# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Feed do
  @moduledoc "A shared source; personal membership lives in subscriptions."
  use Ecto.Schema

  import Ecto.Changeset

  schema "feeds" do
    field :url, :string
    field :title, :string
    field :kind, Ecto.Enum, values: [:youtube, :podcast, :peertube]
    field :icon_url, :string
    field :etag, :string
    field :last_modified, :string
    field :last_checked_at, :utc_datetime_usec
    field :last_error, :string
    timestamps(type: :utc_datetime_usec)
  end

  @video_kinds [:youtube, :peertube]

  @doc "The kinds a reader watches. Everything else is listened to."
  def video_kinds, do: @video_kinds

  @doc "Whether a kind is watched or listened to."
  def medium(kind) when kind in @video_kinds, do: :video
  def medium(_kind), do: :audio

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :url,
      :title,
      :kind,
      :icon_url,
      :etag,
      :last_modified,
      :last_checked_at,
      :last_error
    ])
    |> validate_required([:url, :title, :kind])
    |> validate_length(:title, max: 512)
    |> unique_constraint(:url)
  end
end
