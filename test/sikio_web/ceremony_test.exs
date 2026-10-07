# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CeremonyTest do
  @moduledoc """
  Requests through the ceremony route pipeline that Ithibati's README prescribes.

  The routes once used the `:browser` pipeline. Its `accepts ["html"]` answered the hook's
  request with 406. The README stated the CSRF 403 without a test.
  """
  use SikioWeb.ConnCase

  # `claiming_conn/0` writes the setup code proof into the session.
  # A first-account challenge requires it. The code exchange endpoint has its own tests.
  defp signed_conn do
    conn = claiming_conn() |> get("/setup")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

    {recycle(conn), token}
  end

  test "a ceremony route answers JSON to the request the hook actually makes" do
    {conn, token} = signed_conn()

    response =
      conn
      |> put_req_header("x-csrf-token", token)
      |> put_req_header("accept", "application/json")
      |> post(~p"/auth/registration/challenge", %{"username" => "first_one"})
      |> json_response(200)

    # Ithibati always requires a discoverable credential, in both spellings, and `credProps`.
    # `credProps` reports whether the authenticator created a discoverable credential.
    assert %{"challenge" => _, "rp" => %{"id" => _}} = response
    assert response["authenticatorSelection"]["residentKey"] == "required"
    assert response["authenticatorSelection"]["requireResidentKey"] == true
    assert response["extensions"]["credProps"] == true
  end

  # `Plug.Test` sets `plug_skip_csrf_protection`, which skips the CSRF check.
  # The test sets it to false, so the request goes through the check.
  test "and refuses the same request without a CSRF token" do
    {conn, _token} = signed_conn()

    assert_error_sent(403, fn ->
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("accept", "application/json")
      |> post(~p"/auth/registration/challenge", %{"username" => "first_one"})
    end)
  end
end
