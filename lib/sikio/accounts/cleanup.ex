# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.Cleanup do
  @moduledoc """
  Oban worker that runs `Sikio.AuthCleanup` on the cron schedule in config/config.exs. It also
  deletes expired address requests and unused extension codes.
  `Sikio.AuthCleanup` stays as the starter generates it.

  Expired sessions, challenges, invitations, address requests and codes accumulate, so
  deletion cannot depend on a manual task. One attempt suffices: the next run is fifteen minutes
  later and deletes what a retry would.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl true
  def perform(_job) do
    counts =
      Sikio.AuthCleanup.run()
      |> Map.put(:address_requests, Sikio.AccountAddress.delete_expired())
      |> Map.put(:extension_grants, Sikio.Extensions.delete_expired())

    {:ok, counts}
  end
end
