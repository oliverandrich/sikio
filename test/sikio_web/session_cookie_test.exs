# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SessionCookieTest do
  @moduledoc """
  The session cookie carries the session's validity as its max age.
  A member stays signed in after closing the browser.
  """
  use SikioWeb.ConnCase, async: true

  alias Ithibati.Identity.Sessions

  test "the session cookie carries the session's validity as its max age", %{conn: conn} do
    conn = get(conn, ~p"/login")

    assert %{max_age: max_age} = conn.resp_cookies["_sikio_key"]
    assert max_age == Sessions.max_age()
  end
end
