# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AppIconsTest do
  @moduledoc """
  Every icon linked from the page or listed in the web app manifest is served with its content
  type.
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

    # The wordmark lies inside Android's mask safe zone, so the PNG can be marked maskable.
    assert Enum.any?(icons, &(&1["purpose"] == "maskable"))
  end

  # A stable `id` identifies the installed app. Scope `/` keeps every Sikio page in its window.
  # The shortcuts point to the most used pages.
  test "the manifest names the app, its scope and its shortcuts", %{conn: conn} do
    manifest = served(conn, "/manifest.webmanifest", "application/manifest+json")

    assert %{"id" => "/", "scope" => "/", "shortcuts" => shortcuts} =
             Jason.decode!(manifest.resp_body)

    assert Enum.map(shortcuts, & &1["url"]) == ["/inbox", "/queue", "/add"]
    assert Enum.all?(shortcuts, &(&1["name"] != nil))
  end

  # iOS pauses embedded video in the background in every display mode, so standalone stays.
  test "the installed app opens in its own window", %{conn: conn} do
    manifest = served(conn, "/manifest.webmanifest", "application/manifest+json")

    assert %{"display" => "standalone"} = Jason.decode!(manifest.resp_body)
  end
end
