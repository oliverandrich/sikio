# SPDX-License-Identifier: AGPL-3.0-or-later

Code.require_file("../../scripts/support/support.exs", __DIR__)

defmodule Sikio.ReleaseSmoke.SupportTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Sikio.ReleaseSmoke.Support

  test "command failures never expose stderr or credential-bearing arguments" do
    output =
      capture_io(:stderr, fn ->
        error =
          assert_raise Support.CommandError, fn ->
            Support.run(["sh", "-c", "echo secret-token >&2; exit 1"], %{})
          end

        refute Exception.message(error) =~ "secret-token"
      end)

    assert output == ""
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
