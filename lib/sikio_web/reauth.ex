# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Reauth do
  @moduledoc "Five-minute confirmation bound to the current session account."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  # Each purpose a confirmation is asked for, with the page it returns to.
  @targets %{
    "passkeys" => "/account/passkeys",
    "recovery-codes" => "/account/recovery-codes",
    "accounts" => "/accounts",
    "address" => "/account/address"
  }

  @doc "Returns `{:ok, path}` for a known purpose, else `:error`."
  def target(purpose), do: Map.fetch(@targets, purpose)

  @doc """
  Returns whether `path` is a page a confirmation returns to.

  Connecting an extension returns to `/extension/connect` with the extension's parameters, so
  that path counts with any query.
  """
  def target?(path), do: path in Map.values(@targets) or extension_connect?(path)

  @doc "Returns whether `path` is the extension's connect page, with a query and nothing else."
  def extension_connect?(path) when is_binary(path) do
    match?(
      %URI{scheme: nil, host: nil, path: "/extension/connect", fragment: nil},
      URI.parse(path)
    )
  end

  def extension_connect?(_path), do: false

  # Records a passkey confirmation of `account` in the session.
  defp confirmed_now(conn, %{id: id}) do
    conn
    |> put_session(:confirmed_account_id, id)
    |> put_session(:confirmed_at, System.system_time(:second))
  end

  def recent?(session, account) do
    case {session["confirmed_account_id"], session["confirmed_at"]} do
      {id, at} when id == account.id -> fresh?(at)
      _ -> false
    end
  end

  @doc "Returns whether a confirmation made at `at`, in system seconds, is within five minutes."
  def fresh?(at) when is_integer(at) do
    age = System.system_time(:second) - at
    age >= 0 and age <= 300
  end

  def fresh?(_at), do: false

  def confirmed?(conn), do: recent?(get_session(conn), conn.assigns.current_account)

  def pending?(conn),
    do:
      not is_nil(conn.assigns[:current_account]) and
        target?(get_session(conn, :reauth_target))

  def complete(conn, account, codes \\ nil) do
    case conn.assigns[:current_account] do
      %{id: id} when id == account.id ->
        target = get_session(conn, :reauth_target)

        conn = conn |> delete_session(:reauth_target) |> confirmed_now(account)

        conn = if codes, do: put_session(conn, :recovery_codes, codes), else: conn
        {:ok, json(conn, %{redirect: if(codes, do: "/recovery-codes", else: target)})}

      _ ->
        {:error, :account_mismatch}
    end
  end
end
