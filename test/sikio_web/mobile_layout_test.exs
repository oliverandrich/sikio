# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileLayoutTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  setup :sign_in_with_episode

  test "player can be compacted without removing the active media", %{conn: conn, entry: entry} do
    {:ok, dock, _} = live_isolated(conn, SikioWeb.PlayerDockLive)
    render_hook(dock, "start", %{id: entry.id})
    assert has_element?(dock, "#compact-player[aria-pressed=false]")
    assert has_element?(dock, "audio")
    dock |> element("#compact-player") |> render_click()
    assert has_element?(dock, "#compact-player[aria-pressed=true]")
    assert has_element?(dock, "audio")
    dock |> element("#compact-player") |> render_click()
    assert has_element?(dock, "#compact-player[aria-pressed=false]")
  end
end
