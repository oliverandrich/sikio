# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AppIconsTest do
  @moduledoc """
  The icons a browser, a phone's home screen and an installed app take from the page: every one
  the page names is served, and so is every one the manifest names.
  """
  use SikioWeb.ConnCase, async: true

  defp served(conn, path, type) do
    response = get(recycle(conn), path)
    assert response.status == 200, "#{path} is not served"
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ type, "#{path} is #{content_type}"
    response
  end

  test "the page names its icons and manifest, and each is served", %{conn: conn} do
    page = conn |> get(~p"/setup") |> html_response(200) |> Floki.parse_document!()
    href = &(page |> Floki.attribute(~s|link[rel="#{&1}"]|, "href") |> List.first())

    assert href.("icon")
    served(conn, href.("icon"), "image/")
    assert [svg] = Floki.attribute(page, ~s|link[rel="icon"][type="image/svg+xml"]|, "href")
    served(conn, svg, "image/svg+xml")
    served(conn, href.("apple-touch-icon"), "image/png")

    manifest = served(conn, href.("manifest"), "application/manifest+json")

    assert %{"name" => "Sikio", "icons" => icons, "start_url" => "/"} =
             Jason.decode!(manifest.resp_body)

    for %{"src" => src, "sizes" => sizes} <- icons do
      assert sizes in ["192x192", "512x512"]
      served(conn, src, "image/png")
    end

    assert length(icons) == 2
  end
end
