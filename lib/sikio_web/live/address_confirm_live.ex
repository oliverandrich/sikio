# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddressConfirmLive do
  @moduledoc """
  The page of the link that confirms a new address, in email mode.

  The token follows `#` and arrives from assets/js/token_link.mjs, so no request carries it.
  The page lives outside the member live_session: a redirect to the sign-in would carry the
  fragment there. Signed out, it asks for a sign-in, and the tab keeps the token for the return.

  It confirms only for the signed-in account that asked, with a button, so a mail scanner that
  opens the link changes nothing. The old address is told afterwards.
  """
  use SikioWeb, :live_view

  alias Sikio.AccountAddress
  alias Sikio.Identity
  alias SikioWeb.AccountAddressLive
  alias SikioWeb.AddressMail

  @impl true
  def mount(_params, _session, socket) do
    if Identity.email?(),
      do: {:ok, assign(socket, status: :waiting, token: nil, request: nil, error: nil)},
      else: {:ok, push_navigate(socket, to: ~p"/")}
  end

  # One token per mount. The hook pushes "" when the page was opened without a link.
  @impl true
  def handle_event("address-token", %{"token" => token}, %{assigns: %{status: :waiting}} = socket)
      when is_binary(token) do
    case socket.assigns.current_account do
      nil ->
        {:noreply, assign(socket, status: :signed_out)}

      account ->
        request = if token != "", do: AccountAddress.requested(account, token)
        socket = assign(socket, token: token, request: request, status: :shown)
        {:noreply, if(request, do: socket, else: forget(socket))}
    end
  end

  def handle_event("address-token", _params, socket), do: {:noreply, socket}

  def handle_event("confirm", _params, %{assigns: %{request: %{}}} = socket) do
    case AccountAddress.confirm(socket.assigns.current_account, socket.assigns.token) do
      {:ok, account, old} ->
        {:noreply,
         socket
         |> forget()
         |> told(AddressMail.deliver_notice(old, account.username), account.username)
         |> push_navigate(to: ~p"/account/settings")}

      {:error, :not_found} ->
        {:noreply, socket |> forget() |> assign(request: nil)}

      {:error, reason} ->
        {:noreply,
         socket |> forget() |> assign(error: AccountAddressLive.refusal(reason), request: nil)}
    end
  end

  def handle_event("confirm", _params, socket), do: {:noreply, socket}

  defp forget(socket), do: push_event(socket, "address-token-forget", %{})

  defp told(socket, {:ok, _sent}, address),
    do:
      put_flash(
        socket,
        :info,
        gettext("Your account is identified by %{address} now.", address: address)
      )

  defp told(socket, {:error, _reason}, address),
    do:
      put_flash(
        socket,
        :error,
        gettext(
          "Your account is identified by %{address} now. The old address could not be told.",
          address: address
        )
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={gettext("Email address")}>
      <div id="address-link" phx-hook="TokenLink"></div>
      <div :if={@request} id="address-confirm">
        <p>
          {gettext("Identify your account by %{address} from now on?", address: @request.address)}
        </p>
        <div class="mt-4">
          <Layouts.auth_button phx-click="confirm">{gettext("Change the address")}</Layouts.auth_button>
        </div>
      </div>
      <div :if={@status == :signed_out} id="address-sign-in">
        <p>{gettext("Sign in with the account that asked for the new address.")}</p>
        <.link
          id="address-sign-in-link"
          navigate={~p"/login"}
          class="mt-4 inline-block font-semibold text-link"
        >
          {gettext("Sign in")}
        </.link>
        <p class="mt-3 text-label text-muted">
          {gettext("Then open the link from the mail again.")}
        </p>
      </div>
      <p :if={@status == :shown && !@request && !@error} class="text-muted">
        {gettext(
          "This link is no longer valid. It may have expired, been replaced, or belong to another account."
        )}
      </p>
      <div
        :if={@error}
        role="alert"
        class="rounded-control border p-4 border-danger bg-danger-surface text-danger"
      >
        {@error}
      </div>
    </Layouts.auth>
    """
  end
end
