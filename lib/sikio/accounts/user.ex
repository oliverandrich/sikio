# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.User do
  @moduledoc """
  The account schema, owned by this application. Ithibati contributes the identifier field,
  three associations and the changeset steps that validate the identifier. The rest is this
  application's.
  """
  use Ecto.Schema

  alias Ithibati.Schema.User

  # The format is a `{module, function}` reference, not a regex. It is the only difference
  # between modes, so `Sikio.Identity` returns it per changeset instead of at compile time.
  # A pair, not a capture: the option is escaped into the generated changeset.
  # Only a pair survives that escape unchanged.
  use User,
    identifier: :username,
    format: {Sikio.Identity, :format},
    format_message: {Sikio.Identity, :format_message}

  import Ecto.Changeset

  schema "users" do
    ithibati_account()

    field :name, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> identifier_changeset(attrs)
    |> cast(attrs, [:name])
  end
end
