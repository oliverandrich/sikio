# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.SQLiteFirstStartTest do
  @moduledoc """
  The first start on an empty SQLite file, where every connection of the pool turns the file to
  write-ahead logging at once.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sikio.Repo.SQLite

  @moduletag :tmp_dir

  # One start fails only now and then, so a number of them is what shows it.
  @starts 30
  @pool_size 5

  test "a pool starting on an empty file connects without a locked database", %{tmp_dir: dir} do
    log =
      capture_log(fn ->
        for n <- 1..@starts do
          path = Path.join(dir, "first_start_#{n}.db")
          {:ok, repo} = SQLite.start_link(name: nil, database: path, pool_size: @pool_size)
          await_connections(repo)
          Supervisor.stop(repo)
        end
      end)

    refute log =~ "database is locked"
  end

  # Until every connection of the pool has connected, the failed ones after their retry included.
  defp await_connections(repo, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo)
    [%{ready_conn_count: ready}] = DBConnection.get_connection_metrics(pool)

    cond do
      ready == @pool_size -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("the pool never connected")
      true -> Process.sleep(10) && await_connections(repo, deadline)
    end
  end
end
