# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionConnectLive do
  @moduledoc """
  The browser extension's sign-in window: connects the extension to the signed-in account.

  The extension opens the page with `redirect_uri`, `state`, `code_challenge` and `client`
  through `identity.launchWebAuthFlow`. Connecting needs a passkey confirmation from the last
  five minutes, since the token gives lasting access. The page then hands the extension a
  one-time code at its redirect URI; `SikioWeb.ExtensionTokenController` exchanges it.

  The page is public. Signed out, it links to the sign-in through `SikioWeb.ExtensionReturn`,
  which brings the window back and counts that sign-in as the confirmation.

  The page redirects only to an extension's own redirect URI, which `Sikio.Extensions` checks.
  A redirect happens through LiveView, not a form, since `form-action 'self'` would block it.
  """
  use SikioWeb, :live_view

  alias Sikio.Extensions
  alias SikioWeb.ExtensionReturn
  alias SikioWeb.Reauth

  @fields ["redirect_uri", "state", "code_challenge", "client"]

  @impl true
  def mount(params, session, socket) do
    # A value that is not text, such as `state[a]=1`, counts as missing.
    params =
      for {key, value} <- params, key in @fields, is_binary(value), into: %{}, do: {key, value}

    return = "/extension/connect?" <> URI.encode_query(params)
    # These are read again on each click, so the five minutes still count.
    confirmation =
      Map.take(session, ["confirmed_account_id", "confirmed_at", "extension_confirmed"])

    socket =
      assign(socket,
        page_title: gettext("Connect a browser extension"),
        params: params,
        request: request(params),
        client: Extensions.label(params["client"]),
        confirmation: confirmation,
        confirm_path: ~p"/account/confirm/extension?#{[return: return]}",
        sign_in_path: ~p"/extension/sign-in?#{[return: return]}"
      )

    {:ok, assign(socket, confirmed?: confirmed?(socket.assigns))}
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
    if confirmed?(socket.assigns) do
      # `request/1` checked what `authorize/2` checks, so it issues a code.
      {:ok, code} = Extensions.authorize(socket.assigns.current_account, socket.assigns.params)
      {:noreply, back(socket, code: code)}
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

  defp confirmed?(%{current_account: nil}), do: false

  defp confirmed?(%{confirmation: confirmation, current_account: account}),
    do: Reauth.recent?(confirmation, account) or ExtensionReturn.confirmed?(confirmation, account)

  # The extension's identity API catches this navigation and closes the window.
  defp back(socket, values) do
    query = URI.encode_query(values ++ [state: socket.assigns.params["state"] || ""])
    redirect(socket, external: socket.assigns.params["redirect_uri"] <> "?" <> query)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={gettext("Connect a browser extension")}>
      <div :if={@request == :foreign} role="alert" class="text-danger">
        {gettext("This extension cannot be connected. Its sign-in address is not an extension's.")}
      </div>
      <div :if={@request == :incomplete} role="alert" class="text-danger">
        {gettext("This extension cannot be connected. Its request is incomplete.")}
      </div>
      <div :if={@request == :valid && !@current_account} id="extension-sign-in">
        <p>{gettext("Sign in to connect %{client} to your account.", client: @client)}</p>
        <.link href={@sign_in_path} class="mt-4 inline-block font-semibold text-link">
          {gettext("Sign in")}
        </.link>
      </div>
      <div :if={@request == :valid && @current_account && !@confirmed?}>
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
    </Layouts.auth>
    """
  end
end
