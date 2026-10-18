# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ProdConfigTest do
  @moduledoc """
  Production redirects HTTP to HTTPS and sends HSTS.
  """
  use ExUnit.Case, async: true

  test "production forces HTTPS with HSTS, behind a TLS-terminating proxy as well" do
    force_ssl =
      "config/prod.exs"
      |> Config.Reader.read!(env: :prod)
      |> get_in([:sikio, SikioWeb.Endpoint, :force_ssl])

    assert is_list(force_ssl), "config/prod.exs must set force_ssl"
    # Plug.SSL sends HSTS unless `hsts: false` turns it off.
    assert Keyword.get(force_ssl, :hsts, true)
    assert force_ssl[:rewrite_on] == [:x_forwarded_proto]
    # Not redirected, so a check on the host itself can use plain HTTP.
    assert force_ssl[:exclude][:hosts] == ["localhost", "127.0.0.1"]
  end
end
