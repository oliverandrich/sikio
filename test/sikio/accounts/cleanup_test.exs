# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts.CleanupTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  alias Sikio.Accounts.AddressRequest
  alias Sikio.Accounts.Cleanup
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User

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

  test "the job deletes an expired address request and leaves a current one" do
    ada = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    grace = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    expired = address_request(ada, -60)
    current = address_request(grace, 60)

    assert {:ok, %{address_requests: 1}} = perform_job(Cleanup, %{})
    refute Repo.get(AddressRequest, expired.id)
    assert Repo.get(AddressRequest, current.id)
  end

  test "the job deletes an extension code nobody exchanged in time" do
    ada = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))

    Repo.insert!(%Sikio.Extensions.Grant{
      user_id: ada.id,
      code_digest: :crypto.strong_rand_bytes(32),
      code_challenge: String.duplicate("c", 43),
      redirect_uri: Sikio.ExtensionFixtures.chrome_redirect(),
      label: "Chrome",
      expires_at: DateTime.add(DateTime.utc_now(), -1)
    })

    assert {:ok, %{extension_grants: 1}} = perform_job(Cleanup, %{})
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

  defp address_request(account, seconds),
    do:
      Repo.insert!(%AddressRequest{
        user_id: account.id,
        address: "new@example.org",
        token_digest: :crypto.strong_rand_bytes(32),
        expires_at: DateTime.add(DateTime.utc_now(), seconds)
      })

  defp invitation(opts) do
    {:ok, invitation} =
      %Invitation{}
      |> Invitation.changeset(%{"username" => "grace_hopper"}, opts)
      |> Repo.insert()

    invitation
  end
end
