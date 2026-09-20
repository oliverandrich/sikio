# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.Cleanup do
  @moduledoc """
  The schedule behind `Sikio.AuthCleanup`, which deletes but never decides when.

  Expired sessions, abandoned challenges and unaccepted invitations accumulate on their own, so
  removing them cannot wait for somebody to run a mix task. One attempt, because the next run is
  fifteen minutes away and a retry would only delete what that run deletes anyway.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl true
  def perform(_job), do: {:ok, Sikio.AuthCleanup.run()}
end
