# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.GermanAuthTest do
  use SikioWeb.FeatureCase

  feature "German survives setup, clipboard, sign-out and live recovery navigation", %{
    session: session
  } do
    language(session, "de-DE,de;q=0.9")
    virtual_authenticator(session)

    session
    |> open("/")
    |> assert_has(css("html[lang=de]"))
    |> code_entered()
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Erstelle deinen Passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Speichere deine Wiederherstellungscodes"))
    |> execute_script(
      "Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {writeText: async () => {}}})"
    )
    |> click(button("Wiederherstellungscodes kopieren"))
    |> assert_has(css("#copy-status", text: "Wiederherstellungscodes kopiert."))
    |> click(link("Codes gespeichert. Weiter"))
    |> landed_on("/")
    |> open("/invitations")
    |> assert_has(css("p", text: "Angemeldet als ada."))
    |> connected()
    |> click(css("#user-menu summary"))
    |> click(link("Abmelden"))
    |> landed_on("/login")
    |> click(link("Passkey verloren? Wiederherstellungscode verwenden"))
    |> fill_in(css("input[name=code]"), with: "invalid-code")
    |> click(button("Mit Wiederherstellungscode anmelden"))
    |> assert_has(css("[role=alert]", text: "Dieser Wiederherstellungscode ist ungültig."))
    |> click(link("Zurück zur Passkey-Anmeldung"))
    |> assert_has(button("Mit einem Passkey anmelden"))
  end
end
