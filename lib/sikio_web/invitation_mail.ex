# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationMail do
  @moduledoc """
  Sends an invitation to the address it is addressed to.

  Only where accounts are addressed. Named, there is nothing to send to and nothing to configure:
  the link is handed over however its sender likes. `Sikio.Identity` is what ties the mode to a
  working mail configuration, and it does so where the instance starts, so nothing here asks
  again.

  An invitation exists before any of this and outlives a delivery that failed. The link is the
  only copy there will ever be, so losing it to a mail server that is down would lose the
  invitation with it.
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
    # Swoosh raises rather than answers when its adapter refuses the configuration, and gen_smtp
    # raises on a value it cannot use. By the time this runs the invitation is written and its
    # token exists in this process and nowhere else, so letting either through would lose the
    # link along with the delivery.
    error -> {:error, error}
  end
end
