# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures.CleanupTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Sikio.Pictures.Cleanup

  # The worker deletes nothing unless something runs it, so the schedule is what is asserted.
  test "the schedule runs the job" do
    options = Application.fetch_env!(:sikio, Oban)

    assert :ok = Oban.Config.validate(options)
    assert Enum.any?(options[:cron][:crontab], &match?({_expression, Cleanup}, &1))
  end
end
