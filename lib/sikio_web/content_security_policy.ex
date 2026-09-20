# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ContentSecurityPolicy do
  @moduledoc """
  The one opening that cannot be written in advance.

  The router states the policy every response carries. A PeerTube video is played by the
  instance that holds it, and any host may be one, so this widens `frame-src` by the instances
  this account subscribed to and by nothing else. A signed-out visitor adds nothing, and neither
  does an account that follows no instance.

  It is a plug of its own because it runs after the gate: what may be framed depends on who is
  asking. It adds to what the router wrote rather than replacing it, so the response carries a
  policy even if this never runs.

  It costs one query per document request. It does not run for the socket, so a page keeps the
  policy it loaded with.
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
