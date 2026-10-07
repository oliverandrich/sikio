# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationMail do
  @moduledoc """
  Emails an invitation link to the invitation's address.

  Delivery happens only in email identifier mode. In username mode the inviter passes the link on.
  `Sikio.Identity` validates the mail configuration at startup, so this module does not.

  The invitation is inserted before delivery and survives a failed delivery.
  The link holds the only plaintext token, so a delivery error must not discard it.
  """
  use Gettext, backend: SikioWeb.Gettext

  import Swoosh.Email

  alias Sikio.Identity
  alias Sikio.Mailer

  @doc "Whether an invitation made here is delivered as well as shown."
  def delivers?, do: Identity.email?()

  @doc "Sends the link to the invitation's own identifier, and answers what happened."
  def deliver(invitation, link) do
    if delivers?(), do: send_message(invitation.username, link), else: {:ok, :not_sent}
  end

  defp send_message(address, link) do
    new()
    |> to(address)
    |> from(Application.fetch_env!(:sikio, :mail_from))
    |> subject(gettext("Your invitation to Sikio"))
    |> text_body(
      gettext("Somebody kept you a seat. Create your passkey to join:") <> "\n\n" <> link
    )
    |> Mailer.deliver()
  rescue
    # Swoosh raises when its adapter rejects the configuration; gen_smtp raises on invalid values.
    # The invitation is already inserted, and the plaintext token exists only in this process.
    # Rescuing returns an error, so the caller can still show the link.
    error -> {:error, error}
  end
end
