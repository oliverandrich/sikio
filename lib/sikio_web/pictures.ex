# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Pictures do
  @moduledoc """
  Builds and verifies signed URLs for pictures that Sikio proxies.

  The token holds the candidate URLs and a local fallback, signed with the endpoint's secret.
  Only signed tokens are fetched, so the endpoint is not an open proxy.

  Tokens use a fixed `signed_at` instead of the current time.
  The same picture always gets the same URL, so the browser can cache it.
  """
  @salt "picture reference"
  @fallback "/images/picture.svg"

  @doc "Returns the signed `/pictures/` path for `urls` with `fallback` as the local default."
  def path(urls, fallback \\ @fallback)
      when is_list(urls) and binary_part(fallback, 0, 1) == "/" do
    "/pictures/" <> Phoenix.Token.sign(SikioWeb.Endpoint, @salt, {urls, fallback}, signed_at: 0)
  end

  @doc "Returns `{:ok, {urls, fallback}}` for a valid token, or `:error`."
  def verify(reference) do
    case Phoenix.Token.verify(SikioWeb.Endpoint, @salt, reference, max_age: :infinity) do
      {:ok, signed} -> {:ok, signed}
      {:error, _reason} -> :error
    end
  end
end
