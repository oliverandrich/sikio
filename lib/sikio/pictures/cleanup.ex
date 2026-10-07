# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures.Cleanup do
  @moduledoc """
  Deletes cached pictures not served for thirty days.

  The cache grows with every picture any list displays. One attempt suffices, because the next
  daily run deletes the same files.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @max_age 30 * 86_400

  @impl true
  def perform(_job), do: Sikio.Pictures.prune(@max_age)
end
