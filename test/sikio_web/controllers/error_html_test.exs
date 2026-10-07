# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ErrorHTMLTest do
  use SikioWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    assert render_to_string(SikioWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(SikioWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
