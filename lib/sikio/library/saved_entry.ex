# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.SavedEntry do
  @moduledoc "An entry an account added singly, without following its source."
  use Ecto.Schema

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Entry

  schema "saved_entries" do
    belongs_to :user, User
    belongs_to :entry, Entry
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
