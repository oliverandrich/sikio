# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Extensions.Grant do
  @moduledoc """
  A one-time code for connecting a browser extension, bound to the PKCE challenge and the
  redirect URI it was issued for. The row keeps the code's digest.
  """
  use Ecto.Schema

  schema "extension_grants" do
    belongs_to :user, Sikio.Accounts.User
    field :code_digest, :binary, redact: true
    field :code_challenge, :string
    field :redirect_uri, :string
    field :label, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
