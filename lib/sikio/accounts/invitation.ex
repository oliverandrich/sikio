# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.Invitation do
  @moduledoc """
  The invitations schema, owned by this application like the accounts schema.

  Ithibati adds the invitee's identifier, the token digest, an expiry and an acceptance timestamp.
  What an invitation grants is up to this application. Sikio has no roles, so it adds only the
  inviter association.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Invitation

  # The same identifier as the account schema. `Ithibati.Config` raises when the two differ.
  # The format uses the same reference as the account schema, so the two cannot disagree.
  use Invitation,
    identifier: :username,
    format: {Sikio.Identity, :format},
    format_message: {Sikio.Identity, :format_message}

  schema "invitations" do
    ithibati_invitation()

    # `define_field: false`: `ithibati_invitation/0` already declares `invited_by_id`.
    # A second declaration of one column is a compile error.
    # Ithibati defines the column and its foreign key; the association is this application's.
    # The invitations page preloads it.
    belongs_to :invited_by, Sikio.Accounts.User, define_field: false

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the changeset from `invitation_changeset/3`.

  It applies this instance's format. An invalid changeset skips token generation and the
  accounts lookup.
  """
  def changeset(invitation, attrs, opts \\ []),
    do: invitation_changeset(invitation, attrs, opts)
end
