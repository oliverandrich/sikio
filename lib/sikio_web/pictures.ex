# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Pictures do
  @moduledoc """
  Signed addresses for pictures that Sikio fetches on the reader's behalf.

  The address carries the candidates and a local fallback, signed with the endpoint's secret.
  Only addresses this application wrote are fetched, so the endpoint is no open proxy.

  The signature carries a fixed time instead of the current one. The same picture keeps the same
  address, which is what lets the browser cache it.
  """
  @salt "picture reference"
  @fallback "/images/picture.svg"

  @doc "The address of the first picture among `urls`, or of `fallback` when none can be had."
  def path(urls, fallback \\ @fallback)
      when is_list(urls) and binary_part(fallback, 0, 1) == "/" do
    "/pictures/" <> Phoenix.Token.sign(SikioWeb.Endpoint, @salt, {urls, fallback}, signed_at: 0)
  end

  @doc "The candidates and fallback a reference was signed with, or `:error`."
  def verify(reference) do
    case Phoenix.Token.verify(SikioWeb.Endpoint, @salt, reference, max_age: :infinity) do
      {:ok, signed} -> {:ok, signed}
      {:error, _reason} -> :error
    end
  end
end
