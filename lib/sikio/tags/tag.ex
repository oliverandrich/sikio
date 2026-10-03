# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Tags.Tag do
  @moduledoc "A name an account gives some of its subscriptions, such as \"Must view\"."
  use Ecto.Schema

  alias Sikio.Accounts.User

  schema "tags" do
    belongs_to :user, User
    field :name, :string
    # The name in lowercase, which makes a tag unique within its account.
    field :key, :string
    timestamps(type: :utc_datetime_usec)
  end
end
