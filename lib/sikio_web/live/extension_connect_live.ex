# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionConnectLive do
  @moduledoc """
  The browser extension's sign-in window: connects the extension to the signed-in account.

  The extension opens the page with `redirect_uri`, `state`, `code_challenge` and `client`
  through `identity.launchWebAuthFlow`. Connecting needs a passkey confirmation from the last
  five minutes, since the token gives lasting access. The page then hands the extension a
  one-time code at its redirect URI; `SikioWeb.ExtensionTokenController` exchanges it.

  The page redirects only to an extension's own redirect URI, which `Sikio.Extensions` checks.
  A redirect happens through LiveView, not a form, since `form-action 'self'` would block it.
  """
  use SikioWeb, :live_view

  alias Sikio.Extensions
  alias SikioWeb.Reauth

  @impl true
  def mount(params, session, socket) do
    params = Map.take(params, ["redirect_uri", "state", "code_challenge", "client"])
    return = "/extension/connect?" <> URI.encode_query(params)
    # `Reauth.recent?/2` reads these again on each click, so the five minutes still count.
    confirmation = Map.take(session, ["confirmed_account_id", "confirmed_at"])

    {:ok,
     assign(socket,
       page_title: gettext("Connect a browser extension"),
       params: params,
       request: request(params),
       client: Extensions.label(params["client"]),
       confirmation: confirmation,
       confirmed?: Reauth.recent?(confirmation, socket.assigns.current_account),
       confirm_path: ~p"/account/confirm/extension?#{[return: return]}",
       error: nil
     )}
  end

  # A foreign redirect URI gets no redirect at all. A valid one with a bad challenge goes back
  # with an error, so the extension's window does not wait for nothing.
  defp request(params) do
    cond do
      not Extensions.redirect_uri?(params["redirect_uri"]) -> :foreign
      not Extensions.challenge?(params["code_challenge"]) -> :incomplete
      true -> :valid
    end
  end

  @impl true
  def handle_event("connect", _params, %{assigns: %{request: :valid}} = socket) do
    %{params: params, current_account: account} = socket.assigns

    if confirmed?(socket.assigns) do
      case Extensions.authorize(account, params) do
        {:ok, code} -> {:noreply, back(socket, code: code)}
        {:error, _reason} -> {:noreply, assign(socket, error: invalid())}
      end
    else
      # The confirmation ran out while the page was open, so it asks for the passkey again.
      {:noreply, assign(socket, confirmed?: false)}
    end
  end

  def handle_event("decline", _params, %{assigns: %{request: :valid}} = socket),
    do: {:noreply, back(socket, error: "access_denied")}

  def handle_event("decline", _params, %{assigns: %{request: :incomplete}} = socket),
    do: {:noreply, back(socket, error: "invalid_request")}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Read again on each click, so a confirmation that runs out takes effect.
  defp confirmed?(%{confirmation: confirmation, current_account: account}),
    do: Reauth.recent?(confirmation, account)

  # The extension's identity API catches this navigation and closes the window.
  defp back(socket, values) do
    query = URI.encode_query(values ++ [state: socket.assigns.params["state"] || ""])
    redirect(socket, external: socket.assigns.params["redirect_uri"] <> "?" <> query)
  end

  defp invalid, do: gettext("This extension cannot be connected. Its request is incomplete.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={gettext("Connect a browser extension")}>
      <div :if={@request == :foreign} role="alert" class="text-danger">
        {gettext("This extension cannot be connected. Its sign-in address is not an extension's.")}
      </div>
      <div :if={@request == :incomplete} role="alert" class="text-danger">{invalid()}</div>
      <div :if={@request == :valid && !@confirmed?}>
        <p>{gettext("Confirm with your passkey before %{client} connects.", client: @client)}</p>
        <.link
          id="extension-confirm"
          href={@confirm_path}
          class="mt-4 inline-block font-semibold text-link"
        >
          {gettext("Confirm your identity")}
        </.link>
      </div>
      <div :if={@request == :valid && @confirmed?} id="extension-connect">
        <p>
          {gettext(
            "%{client} can then add sources and items to your library and see what you subscribe to.",
            client: @client
          )}
        </p>
        <div class="mt-4">
          <Layouts.auth_button phx-click="connect">{gettext("Connect")}</Layouts.auth_button>
        </div>
      </div>
      <button
        :if={@request != :foreign}
        id="extension-decline"
        type="button"
        phx-click="decline"
        class="mt-3 w-full text-label text-muted hover:text-ink"
      >
        {if @request == :valid,
          do: gettext("Do not connect"),
          else: gettext("Back to the extension")}
      </button>
      <div :if={@error} role="alert" class="mt-4 text-danger">{@error}</div>
    </Layouts.auth>
    """
  end
end
