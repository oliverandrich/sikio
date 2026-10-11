# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.Favourite do
  @moduledoc "An entry an account starred. The star keeps the entry in the library."
  use Ecto.Schema

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry

  schema "favourites" do
    belongs_to :user, User
    belongs_to :entry, Entry
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
