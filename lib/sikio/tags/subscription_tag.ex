# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Tags.SubscriptionTag do
  @moduledoc "One tag on one subscription."
  use Ecto.Schema

  alias Sikio.Library.Subscription
  alias Sikio.Tags.Tag

  schema "subscription_tags" do
    belongs_to :subscription, Subscription
    belongs_to :tag, Tag
  end
end
