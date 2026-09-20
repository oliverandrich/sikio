# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.HealthController do
  @moduledoc "Public liveness probe; intentionally independent of the database and session."
  use SikioWeb, :controller

  def show(conn, _params) do
    conn |> put_resp_header("cache-control", "no-store") |> json(%{status: "ok"})
  end
end
