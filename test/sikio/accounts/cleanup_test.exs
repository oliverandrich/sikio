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

  # The worker on its own deletes nothing, because nothing runs it. This is the half that says
  # maintenance actually happens on a deployed instance rather than only when somebody remembers.
  #
  # Read from the application environment rather than from `Oban.config/0`: `testing: :manual`
  # empties the running instance's plugins and queues, so the schedule this asserts on is only
  # visible in the configuration. `validate/1` is Oban's own answer to that, and it also refuses a
  # cron expression that would otherwise fail at boot in production and nowhere else.
  test "the schedule runs the job" do
    options = Application.fetch_env!(:sikio, Oban)

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
