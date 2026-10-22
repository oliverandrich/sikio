# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AccountAddressTest do
  @moduledoc """
  Tests changing the address an account is identified by, in email mode.

  A request stores the new address beside the account. Only its confirmation by the same account
  writes the address, so the old one stays in force until then.
  """
  # Not async: these tests set the identifier mode in application env.
  use Sikio.DataCase, async: false

  alias Sikio.AccountAddress
  alias Sikio.Accounts.User
  alias Sikio.Invitations
  alias Sikio.TestConfig

  setup do
    TestConfig.put_env(:sikio, :account_identity, :email)
    ada = Repo.insert!(User.changeset(%User{}, %{username: "ada@example.org"}))
    grace = Repo.insert!(User.changeset(%User{}, %{username: "grace@example.org"}))
    %{ada: ada, grace: grace}
  end

  test "a request keeps the old address until the same account confirms it", c do
    assert {:ok, %{address: "ada@new.example"}, token} =
             AccountAddress.request(c.ada, " Ada@New.example ")

    assert Repo.reload!(c.ada).username == "ada@example.org"
    assert %{address: "ada@new.example"} = AccountAddress.pending(c.ada)

    assert AccountAddress.confirm(c.grace, token) == {:error, :not_found}

    assert {:ok, %User{username: "ada@new.example"}, "ada@example.org"} =
             AccountAddress.confirm(c.ada, token)

    assert AccountAddress.pending(c.ada) == nil
    assert AccountAddress.confirm(c.ada, token) == {:error, :not_found}
  end

  test "a new request replaces the earlier one and its link", c do
    {:ok, _request, first} = AccountAddress.request(c.ada, "one@example.org")
    {:ok, _request, second} = AccountAddress.request(c.ada, "two@example.org")

    assert AccountAddress.confirm(c.ada, first) == {:error, :not_found}
    assert {:ok, %User{username: "two@example.org"}, _old} = AccountAddress.confirm(c.ada, second)
  end

  test "a request refuses an address that names somebody or is promised to somebody", c do
    assert {:error, :taken} = AccountAddress.request(c.ada, "grace@example.org")
    assert {:error, :unchanged} = AccountAddress.request(c.ada, "ada@example.org")
    assert {:error, %Ecto.Changeset{}} = AccountAddress.request(c.ada, "not an address")

    {:ok, _invitation} = Invitations.open(c.grace, %{"username" => "kim@example.org"})
    assert {:error, :invited} = AccountAddress.request(c.ada, "kim@example.org")
  end

  # Another account may take the address between the request and its confirmation.
  test "a confirmation fails when the address was taken meanwhile", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "kim@example.org")
    Repo.insert!(User.changeset(%User{}, %{username: "kim@example.org"}))

    assert {:error, :taken} = AccountAddress.confirm(c.ada, token)
    assert Repo.reload!(c.ada).username == "ada@example.org"
  end

  # An invitation may name the address after the request. Accepting it would then fail.
  test "a confirmation fails when an invitation names the address meanwhile", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "kim@example.org")
    {:ok, _invitation} = Invitations.open(c.grace, %{"username" => "kim@example.org"})

    assert {:error, :invited} = AccountAddress.confirm(c.ada, token)
    assert Repo.reload!(c.ada).username == "ada@example.org"
  end

  # A page may hold the account from before another tab changed the address.
  test "a confirmation names the address the account had, not a stale one", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "kim@example.org")
    Repo.update!(Ecto.Changeset.change(c.ada, username: "ada@moved.example"))

    assert {:ok, _account, "ada@moved.example"} = AccountAddress.confirm(c.ada, token)
  end

  test "a withdrawn request confirms nothing", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "ada@new.example")

    assert :ok = AccountAddress.withdraw(c.ada)
    assert AccountAddress.pending(c.ada) == nil
    assert AccountAddress.confirm(c.ada, token) == {:error, :not_found}
  end

  test "an expired request confirms nothing and is deleted", c do
    {:ok, request, token} = AccountAddress.request(c.ada, "late@example.org")
    {:ok, _fresh, _token} = AccountAddress.request(c.grace, "soon@example.org")
    expire(request)

    assert AccountAddress.confirm(c.ada, token) == {:error, :not_found}
    assert AccountAddress.pending(c.ada) == nil
    assert AccountAddress.delete_expired() == 1
    assert %{address: "soon@example.org"} = AccountAddress.pending(c.grace)
  end

  test "in username mode there is no address to change", c do
    TestConfig.put_env(:sikio, :account_identity, :username)
    assert AccountAddress.request(c.ada, "ada@new.example") == {:error, :username_mode}
  end

  defp expire(request) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    Repo.update!(Ecto.Changeset.change(request, expires_at: past))
  end
end
