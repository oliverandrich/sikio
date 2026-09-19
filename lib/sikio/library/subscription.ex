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
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:paused])
    |> unique_constraint([:user_id, :feed_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:feed_id)
  end
end
