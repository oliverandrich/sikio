# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.Invitation do
  @moduledoc """
  The invitations table is ours, the same arrangement as the accounts table.

  Ithibati adds the invitee's identifier, the token digest, an expiry and an acceptance timestamp;
  what an invitation *grants* is this application's to add. There is nothing here beyond the
  minimum, because this example is about the flow rather than about roles.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Invitation
  alias Sikio.Identity

  import Ecto.Changeset

  # The same identifier the account schema is keyed by — the configuration refuses the pair when it
  # is not, which is the mistake worth catching at boot rather than at the first invitation. The
  # format is left off here for the same reason it is left off there: an instance chooses it.
  use Invitation, identifier: :username

  schema "invitations" do
    ithibati_invitation()

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The invitation, or a refusal that cost nothing to arrive at.

  The shape is asked first. `invitation_changeset/3` mints a token and its digest and asks the
  accounts table whether the name is free, and Ithibati skips both when the changeset is already
  invalid — which is what carrying `:format` there used to buy. Since the format is this
  instance's to choose, the same saving is bought here instead.
  """
  def changeset(invitation, attrs, opts \\ []) do
    value = Identity.given(attrs)

    if is_nil(value) or Identity.shaped?(value) do
      invitation_changeset(invitation, attrs, opts)
    else
      invitation
      |> invitation_changeset(%{}, opts)
      |> put_change(:username, value)
      |> Identity.validate()
    end
  end
end
