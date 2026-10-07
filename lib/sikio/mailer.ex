# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Mailer do
  @moduledoc "Swoosh mailer for invitations in email mode."
  use Swoosh.Mailer, otp_app: :sikio

  @doc """
  Returns whether mail delivery is enabled by `:mail_enabled`.

  `Sikio.Application` passes the result to `Sikio.Identity.verify!/1`, which raises in email mode
  without delivery. The check lives in the sending module, so its definition stays in one place.
  """
  def configured?, do: Application.get_env(:sikio, :mail_enabled, false)
end
