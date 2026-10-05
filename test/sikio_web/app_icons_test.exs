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

    # The wordmark stays inside the circle Android keeps, so the same picture may be cropped.
    assert Enum.any?(icons, &(&1["purpose"] == "maskable"))
  end

  # An installed app knows itself by a stable id and keeps every page of Sikio inside its window.
  # Its shortcuts lead to the places opened most.
  test "the manifest names the app, its scope and its shortcuts", %{conn: conn} do
    manifest = served(conn, "/manifest.webmanifest", "application/manifest+json")

    assert %{"id" => "/", "scope" => "/", "shortcuts" => shortcuts} =
             Jason.decode!(manifest.resp_body)

    assert Enum.map(shortcuts, & &1["url"]) == ["/inbox", "/queue", "/add"]
    assert Enum.all?(shortcuts, &(&1["name"] != nil))
  end
end
