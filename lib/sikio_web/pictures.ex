# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Pictures do
  @moduledoc """
  Builds and verifies signed URLs for pictures that Sikio proxies.

  The token holds the candidates and a local fallback, signed with the endpoint's secret. A
  candidate is a picture's URL or `{:page, url}`; see `Sikio.Pictures.fetch/2`.
  Only signed tokens are fetched, so the endpoint is not an open proxy.

  Tokens use a fixed `signed_at` instead of the current time.
  The same picture always gets the same URL, so the browser can cache it.
  """
  @salt "picture reference"
  @fallback "/images/picture.svg"

  @doc "Returns the signed `/pictures/` path for `candidates` with `fallback` as the default."
  def path(candidates, fallback \\ @fallback)
      when is_list(candidates) and binary_part(fallback, 0, 1) == "/" do
    "/pictures/" <>
      Phoenix.Token.sign(SikioWeb.Endpoint, @salt, {candidates, fallback}, signed_at: 0)
  end

  @doc "Returns `{:ok, {urls, fallback}}` for a valid token, or `:error`."
  def verify(reference) do
    case Phoenix.Token.verify(SikioWeb.Endpoint, @salt, reference, max_age: :infinity) do
      {:ok, signed} -> {:ok, signed}
      {:error, _reason} -> :error
    end
  end
end
