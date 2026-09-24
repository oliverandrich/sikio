# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.User do
  @moduledoc """
  The account table is ours. Ithibati contributes the identifier field, three associations and the
  changeset pieces that validate them — everything else here is this application's.
  """
  use Ecto.Schema

  alias Ithibati.Schema.User

  # The format is named, not written. An instance names its accounts or addresses them, and that
  # is the only thing the two modes differ by, so it is asked of `Sikio.Identity` per changeset
  # rather than fixed here when this compiles. A pair and not a capture: the option is escaped
  # into the generated changeset, and only a pair survives that unchanged.
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
