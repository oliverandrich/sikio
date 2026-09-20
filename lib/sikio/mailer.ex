# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Mailer do
  @moduledoc "Invitation delivery, for an instance that addresses its accounts."
  use Swoosh.Mailer, otp_app: :sikio

  @doc """
  Whether anything here is configured to send.

  Asked by `Sikio.Identity`, which refuses to start an instance that addresses its accounts
  without it. Answered here because this is the module that would do the sending, so if readiness
  ever comes to mean something else, it means it in one place.
  """
  def configured?, do: Application.get_env(:sikio, :mail_enabled, false)
end
