# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Tags.Tag do
  @moduledoc "A name an account gives some of its subscriptions, such as \"Must view\"."
  use Ecto.Schema

  alias Sikio.Accounts.User

  schema "tags" do
    belongs_to :user, User
    field :name, :string
    # The lowercase name. A unique index on user and key keeps names unique per account.
    field :key, :string
    timestamps(type: :utc_datetime_usec)
  end
end
