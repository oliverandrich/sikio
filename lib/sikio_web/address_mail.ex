# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddressMail do
  @moduledoc """
  Mails for changing an account's address: the link to the new address and the notice to the
  old one.

  Both are sent only in email mode, where `Sikio.Identity` has checked the mail configuration.
  A delivery error is returned, not raised, so the page can say so.
  """
  use Gettext, backend: SikioWeb.Gettext

  import Swoosh.Email

  alias Sikio.Mailer

  @doc "Sends the confirmation link to the requested address."
  def deliver_link(address, link) do
    deliver(
      address,
      gettext("Confirm your new address for Sikio"),
      gettext("Confirm that this address identifies your Sikio account from now on:") <>
        "\n\n" <> link <> "\n\n" <> gettext("Ignore this mail if you did not ask for it.")
    )
  end

  @doc "Tells the old address which address identifies the account now."
  def deliver_notice(old_address, new_address) do
    deliver(
      old_address,
      gettext("Your Sikio account has a new address"),
      gettext("Your Sikio account is identified by %{address} from now on.",
        address: new_address
      ) <>
        "\n\n" <>
        gettext("If you did not change it, sign in with your passkey and change it back.")
    )
  end

  defp deliver(address, subject, body) do
    new()
    |> to(address)
    |> from(Application.fetch_env!(:sikio, :mail_from))
    |> subject(subject)
    |> text_body(body)
    |> Mailer.deliver()
  rescue
    # Swoosh raises when its adapter rejects the configuration; gen_smtp raises on invalid values.
    error -> {:error, error}
  end
end
