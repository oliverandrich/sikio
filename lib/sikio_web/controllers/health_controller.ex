# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.HealthController do
  @moduledoc "Public liveness probe. It reads neither the database nor the session."
  use SikioWeb, :controller

  def show(conn, _params) do
    conn |> put_resp_header("cache-control", "no-store") |> json(%{status: "ok"})
  end
end
