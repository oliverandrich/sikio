# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ReleaseTest do
  @moduledoc """
  Tests `Sikio.Release.setup_code/0`, which issues the operator code for the first account.

  Not `async: true`: one test sets the claim mode in application env.
  ExUnit runs synchronous tests after all async tests, so no other test reads it meanwhile.
  """
  use Sikio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ithibati.Identity.Instance
  alias Sikio.TestConfig
  alias SikioWeb.Auth

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

  # A claimed instance needs no code. A printed code would be unusable and suggest success.
  test "an instance somebody already claimed is told so rather than given a code" do
    claim()

    printed =
      capture_io(fn -> assert Sikio.Release.setup_code() == {:error, :already_claimed} end)

    refute printed =~ ~r/[a-zA-Z0-9_-]{32}/
    assert printed =~ "claimed"
  end

  # The command runs through `eval`, which starts no application.
  # The startup check of the claim mode therefore has not run, so `setup_code/0` repeats it.
  test "an instance whose claim is not protected is refused, not given a code" do
    TestConfig.put_env(:ithibati, :initial_claim, :open)

    printed =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/initial_claim/, fn -> Sikio.Release.setup_code() end
      end)

    refute printed =~ ~r/[a-zA-Z0-9_-]{32}/
  end

  defp claim do
    {:ok, _conn} =
      Auth.register(
        claiming_conn(),
        %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)},
        unique_username(),
        %{}
      )
  end
end
