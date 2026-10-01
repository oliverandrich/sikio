# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures.Cleanup do
  @moduledoc """
  Removes pictures nobody was served for thirty days.

  The cache grows with every picture any list ever showed. One attempt, because the next run is a
  day away and would remove the same files.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @max_age 30 * 86_400

  @impl true
  def perform(_job), do: Sikio.Pictures.prune(@max_age)
end
