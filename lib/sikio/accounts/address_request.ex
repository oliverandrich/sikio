# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.AddressRequest do
  @moduledoc """
  An account's open request to be identified by another address.

  The row keeps the token's digest. Only the link carries the token itself.
  """
  use Ecto.Schema

  schema "address_requests" do
    belongs_to :user, Sikio.Accounts.User
    field :address, :string
    field :token_digest, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
