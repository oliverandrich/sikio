# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ExtensionsTest do
  @moduledoc """
  Tests connecting a browser extension: a one-time code with PKCE, exchanged for a token.

  The code serves only the redirect URI and the challenge it was issued for, once and for a
  minute. The token leads to its account until it is disconnected.
  """
  use Sikio.DataCase, async: true

  import Sikio.ExtensionFixtures

  alias Sikio.Accounts.User
  alias Sikio.Extensions

  setup do
    ada = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    grace = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))

    %{
      ada: ada,
      grace: grace,
      verifier: verifier(),
      challenge: challenge(),
      firefox: firefox_redirect(),
      chrome: chrome_redirect()
    }
  end

  defp grant(c, attrs \\ %{}) do
    Extensions.authorize(
      c.ada,
      Map.merge(
        %{"redirect_uri" => c.firefox, "code_challenge" => c.challenge, "client" => "Firefox"},
        attrs
      )
    )
  end

  test "a code and its verifier give a token that leads to the account", c do
    assert {:ok, code} = grant(c)
    assert {:ok, token} = Extensions.exchange(code, c.verifier, c.firefox)

    assert {:ok, %User{id: id}} = Extensions.authenticate(token)
    assert id == c.ada.id
    assert [%{label: "Firefox"}] = Extensions.list(c.ada)
    assert Extensions.list(c.grace) == []
  end

  test "a code serves once, with its verifier and its redirect URI", c do
    {:ok, code} = grant(c)
    assert Extensions.exchange(code, String.duplicate("w", 43), c.firefox) == {:error, :invalid}
    assert Extensions.exchange(code, c.verifier, c.chrome) == {:error, :invalid}

    {:ok, code} = grant(c)
    assert {:ok, _token} = Extensions.exchange(code, c.verifier, c.firefox)
    assert Extensions.exchange(code, c.verifier, c.firefox) == {:error, :invalid}
  end

  # A failed exchange deletes its code; the cleanup takes codes nobody exchanged.
  test "a code expires after a minute", c do
    {:ok, code} = grant(c)
    {:ok, _unused} = grant(c)

    Repo.update_all(Sikio.Extensions.Grant,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert Extensions.exchange(code, c.verifier, c.firefox) == {:error, :invalid}
    assert Extensions.delete_expired() == 1
  end

  # A redirect elsewhere would hand the code to whoever owns that address.
  test "only an extension's redirect URI and an S256 challenge are accepted", c do
    assert {:ok, _code} = grant(c, %{"redirect_uri" => c.chrome})

    for uri <- [
          foreign_redirect(),
          String.replace(c.firefox, ".org/", ".org.evil.example/"),
          String.replace(c.firefox, "https://", "http://"),
          nil
        ] do
      assert grant(c, %{"redirect_uri" => uri}) == {:error, :redirect_uri}
    end

    assert grant(c, %{"code_challenge" => "short"}) == {:error, :code_challenge}
  end

  test "a disconnected token leads nowhere", c do
    {:ok, code} = grant(c)
    {:ok, token} = Extensions.exchange(code, c.verifier, c.firefox)
    [connected] = Extensions.list(c.ada)

    assert Extensions.revoke(c.grace, connected.id) == {:error, :not_found}
    assert :ok = Extensions.revoke(c.ada, connected.id)
    assert Extensions.authenticate(token) == :error
    assert Extensions.authenticate("unknown") == :error
  end
end
