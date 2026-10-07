# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.StaticAssetsTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  # A release build leaves gzip copies in priv/static. The test endpoint must serve the files
  # `mix assets.build` just wrote. Otherwise browser tests run the last release's bundle.
  test "the test endpoint serves a built file, not a compressed copy left beside it", %{
    conn: conn
  } do
    name = "probe-#{System.unique_integer([:positive])}.txt"
    path = Application.app_dir(:sikio, ["priv", "static", "assets", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "fresh")
    File.write!(path <> ".gz", :zlib.gzip("stale"))

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".gz")
    end)

    conn = conn |> put_req_header("accept-encoding", "gzip") |> get("/assets/#{name}")

    assert response(conn, 200) == "fresh"
  end
end
