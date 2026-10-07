# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.Cleanup do
  @moduledoc """
  Oban worker that runs `Sikio.AuthCleanup` on the cron schedule in config/config.exs.

  Expired sessions, challenges and invitations accumulate, so deletion cannot depend on a manual
  task. One attempt suffices: the next run is fifteen minutes later and deletes what a retry
  would.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl true
  def perform(_job), do: {:ok, Sikio.AuthCleanup.run()}
end
