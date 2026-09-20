# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ReleaseTest do
  @moduledoc """
  The command an operator runs before anybody can claim a fresh instance.

  Not `async: true`: the claim mode is application configuration, and these set it. Synchronous
  tests run after every concurrent one, so nothing else is reading it while they do.
  """
  use Sikio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ithibati.Identity.Instance
  alias SikioWeb.Auth

  setup do
    # Put back what was there, and when nothing was, take the key away again. Writing nil into
    # it is not the same as leaving it unset: the library reads nil and refuses it, where an
    # absent key is its default.
    previous = Application.fetch_env(:ithibati, :initial_claim)
    Application.put_env(:ithibati, :initial_claim, :operator_code)

    on_exit(fn ->
      case previous do
        {:ok, mode} -> Application.put_env(:ithibati, :initial_claim, mode)
        :error -> Application.delete_env(:ithibati, :initial_claim)
      end
    end)
  end

  test "prints a code once, and nothing else" do
    printed = capture_io(fn -> assert Sikio.Release.setup_code() == :ok end)
    lines = String.split(printed, "\n", trim: true)

    assert [_sentence, code] = lines, "the code is shown once, with one line saying what it is"
    assert String.length(code) >= 32
    assert {:ok, _proof} = Instance.authorize_code(code)
  end

  test "a second issue leaves the first code worthless" do
    first =
      capture_io(fn -> Sikio.Release.setup_code() end)
      |> String.split("\n", trim: true)
      |> List.last()

    second =
      capture_io(fn -> Sikio.Release.setup_code() end)
      |> String.split("\n", trim: true)
      |> List.last()

    refute first == second
    assert {:error, _} = Instance.authorize_code(first)
    assert {:ok, _proof} = Instance.authorize_code(second)
  end

  # An instance with an account needs no code, and printing one that nobody can spend would be
  # worse than saying so: it reads like the command worked.
  #
  # Claimed while the mode was still open, which is the shape every instance upgrading to this
  # version has.
  test "an instance somebody already claimed is told so rather than given a code" do
    claim_while_open()

    printed =
      capture_io(fn -> assert Sikio.Release.setup_code() == {:error, :already_claimed} end)

    refute printed =~ ~r/[a-zA-Z0-9_-]{32}/
    assert printed =~ "claimed"
  end

  # An operator on an instance that does not protect its claim gets a sentence, not the stack
  # trace of a library saying the configuration is wrong. There is nothing to fix here: an open
  # instance needs no code.
  test "an instance that does not protect its claim says so" do
    Application.put_env(:ithibati, :initial_claim, :open)

    printed = capture_io(fn -> assert Sikio.Release.setup_code() == {:error, :claim_is_open} end)

    refute printed =~ ~r/[a-zA-Z0-9_-]{32}/
    assert printed =~ "open"
  end

  defp claim_while_open do
    Application.put_env(:ithibati, :initial_claim, :open)

    {:ok, _conn} =
      Auth.register(
        Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{}),
        %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)},
        unique_username(),
        %{}
      )

    Application.put_env(:ithibati, :initial_claim, :operator_code)
  end
end
