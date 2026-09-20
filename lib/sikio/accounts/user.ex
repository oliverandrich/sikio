# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.User do
  @moduledoc """
  The account table is ours. Ithibati contributes the identifier field, three associations and the
  changeset pieces that validate them — everything else here is this application's.
  """
  use Ecto.Schema

  alias Ithibati.Schema.User
  alias Sikio.Identity

  # The format is left off on purpose. An instance names its accounts or addresses them, and that
  # is the only thing the two modes differ by, so it is asked of `Sikio.Identity` per changeset
  # rather than fixed here when this compiles. Ithibati still requires, trims, lowercases and caps
  # the value; `changeset/2` below adds the shape.
  use User, identifier: :username

  import Ecto.Changeset

  schema "users" do
    ithibati_account()

    field :name, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> identifier_changeset(attrs)
    |> Identity.validate()
    |> cast(attrs, [:name])
  end
end
