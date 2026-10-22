# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ExtensionFixtures do
  @moduledoc """
  Redirect URIs for browser extension tests, unique per call, so concurrent tests share none.
  """

  @doc "Returns a Firefox extension's redirect URI with a 40-character hex id."
  def firefox_redirect,
    do:
      "https://#{Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)}.extensions.allizom.org/"

  @doc "Returns a Chrome extension's redirect URI with a 32-letter id from a to p."
  def chrome_redirect do
    id = for <<nibble::4 <- :crypto.strong_rand_bytes(16)>>, into: "", do: <<?a + nibble>>
    "https://#{id}.chromiumapp.org/"
  end

  @doc "Returns an address that is no extension's."
  def foreign_redirect, do: "https://site#{Sikio.DataCase.unique()}.example/"
end
