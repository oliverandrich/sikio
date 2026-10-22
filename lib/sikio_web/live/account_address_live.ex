# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountAddressLive do
  @moduledoc """
  Asks for a new address to identify the account by, in email mode, and mails the link there.

  Asking needs a passkey confirmation from the last five minutes, so a stolen session cannot move
  the account quietly. Each request mails a typed address, so it counts against the account's
  `address` budget in `Sikio.AuthRateLimiter`. `SikioWeb.AddressConfirmLive` is the link's page.

  In username mode there is no address to change, and the page leads back to the settings.
  """
  use SikioWeb, :live_view

  alias Sikio.AccountAddress
  alias Sikio.AuthRateLimiter
  alias Sikio.Identity
  alias SikioWeb.AddressMail
  alias SikioWeb.AuthRateLimit
  alias SikioWeb.MediaComponents
  alias SikioWeb.Reauth

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        page_title: gettext("Email address"),
        # `Reauth.recent?/2` reads these again on submit, so the five minutes still count.
        confirmation: Map.take(session, ["confirmed_account_id", "confirmed_at"]),
        # Minutes the browser is ahead of UTC, for the expiry date.
        time_zone_offset: time_zone_offset(get_connect_params(socket)),
        address: "",
        error: nil
      )

    cond do
      not Identity.email?() ->
        {:ok, push_navigate(socket, to: ~p"/account/settings")}

      not confirmed?(socket) ->
        {:ok, redirect(socket, to: ~p"/account/confirm/address")}

      true ->
        {:ok, assign(socket, pending: AccountAddress.pending(socket.assigns.current_account))}
    end
  end

  defp time_zone_offset(%{"time_zone_offset" => offset}) when is_integer(offset), do: offset
  defp time_zone_offset(_params), do: 0

  @impl true
  def handle_event("validate", %{"address" => address}, socket),
    do: {:noreply, assign(socket, address: address, error: nil)}

  # The budget is checked first, so invalid attempts count too, as for invitations.
  def handle_event("request", %{"address" => address}, socket) do
    {limit, seconds} = AuthRateLimiter.budget(:address)
    key = AuthRateLimit.key(socket.assigns.current_account, :address)

    cond do
      not confirmed?(socket) ->
        {:noreply, redirect(socket, to: ~p"/account/confirm/address")}

      match?({:error, _}, AuthRateLimiter.check(key, limit, seconds)) ->
        {:noreply, assign(socket, address: address, error: too_many())}

      true ->
        {:noreply, requested(socket, address)}
    end
  end

  # A request whose link could not be mailed would wait for nothing, so it is withdrawn.
  defp requested(socket, address) do
    account = socket.assigns.current_account

    case AccountAddress.request(account, address) do
      {:ok, request, token} ->
        link = url(~p"/account/address/confirm") <> "#" <> token

        case AddressMail.deliver_link(request.address, link) do
          {:ok, _sent} ->
            assign(socket, pending: request, address: "", error: nil)

          {:error, _reason} ->
            :ok = AccountAddress.withdraw(account)
            error = gettext("The link could not be sent. Try again.")
            assign(socket, pending: nil, address: address, error: error)
        end

      {:error, reason} ->
        assign(socket, address: address, error: refusal(reason))
    end
  end

  @doc "Returns the message for a refused request or confirmation."
  def refusal(:unchanged), do: gettext("This address already identifies your account.")
  def refusal(:taken), do: gettext("This address already names another account.")

  def refusal(:invited),
    do: gettext("An open invitation names this address. Withdraw it first, or wait for it.")

  def refusal(_changeset), do: gettext("Enter a valid email address.")

  defp too_many, do: gettext("Too many requests for a new address. Try again tomorrow.")

  defp confirmed?(socket),
    do: Reauth.recent?(socket.assigns.confirmation, socket.assigns.current_account)

  defp expiry(at, offset), do: at |> DateTime.add(offset, :minute) |> MediaComponents.date()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:account}
      title={gettext("Email address")}
      back={%{to: ~p"/account/settings", label: gettext("Settings")}}
      breadcrumb
    >
      <.header>
        {gettext("Email address")}
        <:subtitle>{@current_account.username}</:subtitle>
      </.header>

      <div class="mt-6 max-w-sm">
        <p class="text-muted">
          {gettext(
            "Your account is identified by this address. A new one takes effect once you follow the link sent there. Your passkeys and sessions stay."
          )}
        </p>
        <form id="address-form" phx-change="validate" phx-submit="request" class="mt-4">
          <.input
            type="email"
            name="address"
            value={@address}
            label={gettext("New email address")}
            required
            placeholder="name@example.org"
          />
          <.button variant="primary">{gettext("Send the link")}</.button>
        </form>
        <p :if={@pending} id="address-pending" class="mt-4 text-label text-muted">
          {gettext("A link to %{address} is waiting to be followed until %{date}.",
            address: @pending.address,
            date: expiry(@pending.expires_at, @time_zone_offset)
          )}
        </p>
        <div
          :if={@error}
          role="alert"
          class="mt-4 rounded-control border p-4 border-danger bg-danger-surface text-danger"
        >
          {@error}
        </div>
      </div>
    </Layouts.member>
    """
  end
end
