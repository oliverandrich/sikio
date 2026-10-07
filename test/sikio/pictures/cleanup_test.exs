# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures.CleanupTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Sikio.Pictures.Cleanup

  # Asserts that the Oban crontab includes the worker, since an unscheduled worker never runs.
  test "the schedule runs the job" do
    options = Sikio.Application.oban()

    assert :ok = Oban.Config.validate(options)
    assert Enum.any?(options[:cron][:crontab], &match?({_expression, Cleanup}, &1))
  end
end
