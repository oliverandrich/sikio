# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CeremonyMessagesTest do
  @moduledoc """
  Every Ithibati ceremony code maps to an application message.

  `Ithibati.Ceremony.codes/0` lists all codes. A new code fails this suite instead of showing raw.
  Three codes come from this application: `already_claimed`, `identifier_mismatch` and
  `setup_authorization_required`.
  """
  use SikioWeb.ConnCase

  import Phoenix.LiveViewTest

  alias SikioWeb.CeremonyMessages

  test "every code the library can send has a sentence of this application's own" do
    for code <- Ithibati.Ceremony.codes() do
      refute CeremonyMessages.message(to_string(code), nil) =~ "Something went wrong",
             "#{code} falls to the catch-all, so the page would show the code itself"
    end
  end

  test "and the three this application produces itself" do
    refute CeremonyMessages.message("already_claimed", nil) =~ "Something went wrong"
    refute CeremonyMessages.message("identifier_mismatch", nil) =~ "Something went wrong"
    refute CeremonyMessages.message("setup_authorization_required", nil) =~ "Something went wrong"
  end

  # The set of codes is open, so the catch-all clause is intended.
  test "while a code nobody listed still says something" do
    assert CeremonyMessages.message("http_502", nil) == "Something went wrong: http_502"
  end

  # Runs through the LiveView, because the two-argument clause only matters if callers use it.
  # An earlier version had the clause, but both pages passed one argument.
  test "and the page hands on the name the browser gave" do
    {:ok, view, _html} = live(build_conn(), ~p"/setup")

    html =
      view
      |> element("#passkey")
      |> render_hook("ithibati:failed", %{
        "error" => "ceremony_failed",
        "exception" => "SecurityError"
      })

    assert html =~ "Your browser refused: SecurityError."
  end
end
