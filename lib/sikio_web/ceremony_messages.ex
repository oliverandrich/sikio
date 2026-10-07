# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CeremonyMessages do
  @moduledoc """
  Translates ceremony error codes into user-facing messages.

  Codes come from `SikioWeb.Auth` and from Ithibati. Ithibati ships no wording.
  Every LiveView that starts a ceremony calls this module, so each code has one message.
  """

  use Gettext, backend: SikioWeb.Gettext

  alias Sikio.Identity

  @doc """
  Returns the message for an `ithibati:failed` code, or a generic message for an unlisted code.

  `name` is the payload's `exception` value. It is the `DOMException` name when the browser
  refused the ceremony, and `nil` otherwise.
  """
  def message("ceremony_failed", name) when is_binary(name),
    do: gettext("Your browser refused: %{name}.", name: name)

  def message(code, _name), do: sentence(code)

  defp sentence("rate_limited"),
    do: gettext("Too many attempts. Please wait a minute and try again.")

  defp sentence("reauthentication_required"),
    do: gettext("Please confirm your identity again in your account settings.")

  defp sentence("account_mismatch"),
    do: gettext("Use a passkey or recovery code belonging to your current account.")

  defp sentence("authentication_required"),
    do: gettext("Please sign in again before adding a passkey.")

  defp sentence("invitation_required"), do: gettext("This instance is invitation-only.")

  defp sentence("invitation_unknown"),
    do: gettext("That invitation has been used, or has expired.")

  # Ithibati uses `username` codes for both identifier modes.
  # These messages depend on `Identity.email?/0`, so they name a username or an email address.
  defp sentence("username_taken") do
    if Identity.email?(),
      do: gettext("That address already has an account."),
      else: gettext("That username is taken.")
  end

  defp sentence("invalid_username") do
    if Identity.email?(),
      do: gettext("That is not an email address."),
      else: gettext("A username is letters, digits and underscores, up to thirty characters.")
  end

  defp sentence("username_required") do
    if Identity.email?(),
      do: gettext("Enter the address that will claim this instance."),
      else: gettext("Pick a username to claim this instance.")
  end

  defp sentence("no_credentials"), do: gettext("No passkey is registered here yet.")
  defp sentence("ceremony_cancelled"), do: gettext("The passkey prompt was dismissed.")

  defp sentence("already_enrolled"),
    do: gettext("That device already holds a passkey for this site.")

  # Sikio reaches these three codes: a concurrent first-account claim, an invitation accepted
  # under another identifier, and a setup proof that expired or was replaced.
  defp sentence("already_claimed"),
    do: gettext("Somebody else has already claimed this instance.")

  defp sentence("setup_authorization_required"),
    do: gettext("Enter the setup code again. The one you used has expired or been replaced.")

  defp sentence("identifier_mismatch") do
    if Identity.email?(),
      do: gettext("That invitation was not addressed to that address."),
      else: gettext("That invitation was not addressed to that username.")
  end

  defp sentence("invalid_code"), do: gettext("That recovery code is not one we can use.")
  defp sentence("no_challenge"), do: gettext("That took too long. Start again.")

  defp sentence("malformed_credential"),
    do: gettext("Your browser sent something this site cannot read.")

  defp sentence("not_discoverable"),
    do: gettext("That device will not store a passkey this site can find.")

  defp sentence("unknown_credential"), do: gettext("That passkey is not one this site knows.")
  defp sentence("no_attested_credential"), do: gettext("Your browser sent no passkey to store.")

  defp sentence("credential_id_too_long"),
    do: gettext("That passkey is bigger than this site can store.")

  defp sentence("verification_failed"), do: gettext("That did not check out. Start again.")
  defp sentence("ceremony_failed"), do: gettext("Your browser stopped partway through.")
  defp sentence("recovery_failed"), do: gettext("That code never reached us. Try again.")
  defp sentence("unknown"), do: gettext("That request failed without saying why.")

  # Matches unlisted codes, including the suffixed `http_*` and `missing_data_*` codes.
  defp sentence(other), do: gettext("Something went wrong: %{reason}", reason: other)
end
