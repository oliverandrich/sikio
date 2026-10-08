# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.HubSync do
  @moduledoc """
  Hourly sync of the WebSub subscriptions with the followed YouTube feeds; see `Sikio.Feeds.Hub`.
  The callback base is the instance's public URL from `PHX_HOST`.
  """
  # The maintenance queue, so a run of hub requests never holds up feed refreshes.
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 60]

  alias Sikio.Feeds.Hub

  @impl true
  def perform(_job) do
    Hub.sync(DateTime.utc_now(), SikioWeb.Endpoint.url() <> "/websub/")
    :ok
  end
end
