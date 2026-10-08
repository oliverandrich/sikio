# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Hub.Subscription do
  @moduledoc """
  A shared feed's WebSub subscription at its hub.

  `token` is the last segment of the callback URL. `secret` signs the content the hub pushes.
  The state is `:pending` until the hub verifies the callback, `:active` after that, and
  `:denied` when the hub refuses. A verification sets the lease and `renew_at`.
  """
  use Ecto.Schema

  alias Sikio.Feeds.Feed

  schema "hub_subscriptions" do
    belongs_to :feed, Feed
    field :token, :string, redact: true
    field :secret, :string, redact: true
    field :state, Ecto.Enum, values: [:pending, :active, :denied], default: :pending
    field :requested_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    # Four fifths into the lease, when the subscription is asked for again.
    field :renew_at, :utc_datetime_usec
    # The video the latest push announced. Until the feed holds it, the feed polls at the base
    # interval, since YouTube's feed can lag behind the push.
    field :awaiting, :string
    timestamps(type: :utc_datetime_usec)
  end
end
