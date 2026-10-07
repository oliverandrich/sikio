# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.Subscription do
  @moduledoc "One account's subscription and polling preference."
  use Ecto.Schema

  import Ecto.Changeset

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed

  schema "subscriptions" do
    belongs_to :user, User
    belongs_to :feed, Feed
    field :paused, :boolean, default: false
    # A name of the account's own for the source; nil, the feed's title stands.
    field :name, :string
    # Where what the source publishes next goes: the inbox, the end of the queue, or the archive.
    field :delivery, Ecto.Enum, values: [:inbox, :queue, :skip], default: :inbox
    # Whether a YouTube channel's Shorts show. A new subscription leaves them out.
    field :shorts, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The settings an account changes itself: a name of its own, where new entries go, and whether
  a YouTube channel's Shorts show.
  """
  def settings_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:name, :delivery, :shorts], empty_values: [])
    |> update_change(:name, &blank_to_nil/1)
    |> validate_length(:name, max: 200)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:paused])
    |> unique_constraint([:user_id, :feed_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:feed_id)
  end
end
