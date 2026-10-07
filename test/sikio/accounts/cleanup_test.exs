# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.CleanupTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  alias Sikio.Accounts.Cleanup
  alias Sikio.Accounts.Invitation

  test "the job deletes an invitation that expired without being accepted" do
    invitation = invitation(days: -1)

    assert {:ok, %{invitations: 1}} = perform_job(Cleanup, %{})
    refute Repo.get(Invitation, invitation.id)
  end

  test "the job leaves an invitation that is still open" do
    invitation = invitation(days: 7)

    assert {:ok, %{invitations: 0}} = perform_job(Cleanup, %{})
    assert Repo.get(Invitation, invitation.id)
  end

  # Asserts that the Oban crontab includes the worker, since an unscheduled worker never runs.
  #
  # Reads `Sikio.Application.oban/0`, not `Oban.config/0`. `testing: :manual` removes plugins and
  # queues from the running instance. `Oban.Config.validate/1` also rejects an invalid cron
  # expression, which would otherwise fail only at production boot.
  test "the schedule runs the job" do
    options = Sikio.Application.oban()

    assert :ok = Oban.Config.validate(options)
    assert Enum.any?(options[:cron][:crontab], &match?({_expression, Cleanup}, &1))
  end

  defp invitation(opts) do
    {:ok, invitation} =
      %Invitation{}
      |> Invitation.changeset(%{"username" => "grace_hopper"}, opts)
      |> Repo.insert()

    invitation
  end
end
