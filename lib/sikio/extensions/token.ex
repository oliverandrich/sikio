# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Extensions.Token do
  @moduledoc "A connected browser extension. The row keeps the token's digest."
  use Ecto.Schema

  schema "extension_tokens" do
    belongs_to :user, Sikio.Accounts.User
    field :token_digest, :binary, redact: true
    field :label, :string
    field :last_used_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
