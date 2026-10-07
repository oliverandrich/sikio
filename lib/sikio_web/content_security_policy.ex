# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ContentSecurityPolicy do
  @moduledoc """
  Adds the account's PeerTube instances to the CSP `frame-src` directive.

  The router sets the base policy on every response. PeerTube videos are embedded from their
  instance, which can be any host. This plug appends the origins of the account's subscribed
  instances and nothing else. Signed-out requests and accounts without instances keep the base
  policy.

  It runs after `Ithibati.Web.Gate`, because the origins depend on `current_account`.
  It extends the router's header instead of replacing it. Without this plug the base policy
  still applies.

  It runs one query per HTTP request. LiveView socket messages do not pass through it, so a
  page keeps the policy it was loaded with.
  """
  @behaviour Plug

  import Plug.Conn

  alias Sikio.Library

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case instances(conn) do
      [] -> conn
      instances -> widen(conn, instances)
    end
  end

  defp widen(conn, instances) do
    case get_resp_header(conn, "content-security-policy") do
      [policy] -> put_resp_header(conn, "content-security-policy", frame(policy, instances))
      _ -> conn
    end
  end

  defp frame(policy, instances) do
    policy
    |> String.split("; ")
    |> Enum.map_join("; ", fn
      "frame-src " <> sources -> Enum.join(["frame-src", sources | instances], " ")
      directive -> directive
    end)
  end

  defp instances(%{assigns: %{current_account: %{} = account}}),
    do: Library.player_origins(account)

  defp instances(_conn), do: []
end
