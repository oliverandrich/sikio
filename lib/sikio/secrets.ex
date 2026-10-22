# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Secrets do
  @moduledoc """
  One-time tokens for links and codes, and the digests stored in their place.

  A token is 32 random bytes in base64url without padding. The database keeps only its SHA-256
  digest, so a leaked row reveals no usable token.
  """

  @doc "Returns a new token."
  def token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc "Returns the digest stored for `token`."
  def digest(token), do: :crypto.hash(:sha256, token)
end
