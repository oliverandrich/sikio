# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.HealthTest do
  use SikioWeb.ConnCase, async: true

  test "health is public and never touches the session", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
    assert conn.resp_cookies == %{}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
