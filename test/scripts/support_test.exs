# SPDX-License-Identifier: AGPL-3.0-or-later

Code.require_file("../../scripts/support/support.exs", __DIR__)

defmodule Sikio.ReleaseSmoke.SupportTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Sikio.ReleaseSmoke.Support

  # The secret is in the arguments and in what the command writes to stderr, so both halves of
  # this test's name are asked of the same word.
  #
  # What is captured here is the group leader, which belongs to the whole machine rather than to
  # this call: a compiler warning emitted while the block runs lands in it as readily as anything
  # this test caused. Asking that it be empty therefore failed on warnings from elsewhere and
  # named a file nowhere near the failure. Asking that the secret is absent says what was meant.
  test "command failures never expose stderr or credential-bearing arguments" do
    output =
      capture_io(:stderr, fn ->
        error =
          assert_raise Support.CommandError, fn ->
            Support.run(["sh", "-c", "echo secret-token >&2; exit 1"], %{})
          end

        refute Exception.message(error) =~ "secret-token"
      end)

    refute output =~ "secret-token"
  end

  test "command arguments stay literal and binary dumps stream to disk" do
    assert Support.run(["printf", "%s", "$(exit 42); \"quoted\""], %{}) ==
             "$(exit 42); \"quoted\""

    Support.temporary(fn directory ->
      path = Path.join(directory, "dump")
      assert Support.run(["printf", "\\000\\377\\012"], %{}, stdout: path) == ""
      assert File.read!(path) == <<0, 255, 10>>
    end)
  end

  test "temporary data is private and cleaned after errors" do
    assert_raise RuntimeError, "probe", fn ->
      Support.temporary(fn directory ->
        send(self(), {:temporary, directory})
        assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
        raise "probe"
      end)
    end

    assert_received {:temporary, directory}
    refute File.exists?(directory)
  end
end
