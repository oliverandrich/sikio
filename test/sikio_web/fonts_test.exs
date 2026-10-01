# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.FontsTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  # The typeface is served from this host, so the content security policy needs no font origin.
  # A path the stylesheet names but the endpoint does not serve falls back to a system face
  # without any error, which is why it is asked here.
  test "every font the stylesheet names is served from this host", %{conn: conn} do
    stylesheet = File.read!("assets/css/app.css")
    fonts = Regex.scan(~r{url\((/fonts/[^)]+\.woff2)\)}, stylesheet, capture: :all_but_first)

    assert fonts != [], "the stylesheet names no self-hosted font"

    for [path] <- fonts do
      response = get(conn, path)
      assert response.status == 200, "#{path} is not served"
      assert get_resp_header(response, "content-type") == ["font/woff2"]
    end
  end
end
