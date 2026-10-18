# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlatformsLive do
  @moduledoc """
  Switches the platforms members may add from, for an administrator. A change saves at once.

  `SikioWeb.Admin` turns members away before `mount/3` runs. `Sikio.Platforms.set/3` checks the
  role again in its query.
  """
  use SikioWeb, :live_view

  alias Sikio.Platforms
  alias SikioWeb.Admin

  on_mount {SikioWeb.Admin, :require_admin}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Platforms"),
       platforms: Platforms.enabled(),
       saved?: false
     )}
  end

  # Each switch posts its state; an unchecked one sends only its hidden `false`.
  @impl true
  def handle_event("save", params, socket) do
    wanted = Map.get(params, "platforms", %{})
    account = socket.assigns.current_account

    result =
      Enum.reduce_while(Platforms.kinds(), {:ok, socket.assigns.platforms}, fn kind, acc ->
        on? = wanted[Atom.to_string(kind)] == "true"

        if on? == socket.assigns.platforms[kind],
          do: {:cont, acc},
          else: halt_on_error(Platforms.set(account, kind, on?))
      end)

    case result do
      {:ok, platforms} ->
        {:noreply, assign(socket, platforms: platforms, saved?: true)}

      {:error, :forbidden} ->
        {:noreply, Admin.turn_away(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Nothing changed. Please try again."))}
    end
  end

  defp halt_on_error({:ok, _platforms} = ok), do: {:cont, ok}
  defp halt_on_error(error), do: {:halt, error}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:platforms}
      title={gettext("Platforms")}
      back={%{to: ~p"/account/settings", label: gettext("Settings")}}
      breadcrumb
    >
      <.header>
        {gettext("Platforms")}
        <:subtitle>
          {gettext(
            "New sources and items can be added only from platforms that are on. Existing subscriptions keep refreshing and playing."
          )}
        </:subtitle>
      </.header>
      <form id="platforms-form" phx-change="save" class="mt-6 max-w-xl">
        <.group id="platforms" heading={gettext("Platforms")}>
          <div
            :for={kind <- Platforms.kinds()}
            class="flex min-h-12 items-center justify-between gap-4 px-4 py-2.5"
          >
            <label for={"platform-#{kind}"} class="block text-body text-ink">{label(kind)}</label>
            <span class="relative inline-flex shrink-0">
              <input type="hidden" name={"platforms[#{kind}]"} value="false" />
              <input
                id={"platform-#{kind}"}
                type="checkbox"
                role="switch"
                name={"platforms[#{kind}]"}
                value="true"
                checked={@platforms[kind]}
                class="peer absolute inset-0 size-full cursor-pointer appearance-none rounded-full"
              />
              <span
                aria-hidden="true"
                class="pointer-events-none h-6 w-10 rounded-full bg-track transition-colors peer-checked:bg-accent peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent forced-colors:border forced-colors:border-[CanvasText] forced-colors:peer-checked:bg-[Highlight]"
              ></span>
              <span
                aria-hidden="true"
                class="pointer-events-none absolute top-0.5 left-0.5 size-5 rounded-full bg-surface shadow-xs transition-transform peer-checked:translate-x-4 forced-colors:bg-[CanvasText]"
              ></span>
            </span>
          </div>
        </.group>
      </form>
      <%!-- The status region exists from the start, so screen readers announce its text. --%>
      <p id="platforms-saved" role="status" class="mt-2 px-4 text-label text-muted">
        {if @saved?, do: gettext("Saved.")}
      </p>
    </Layouts.member>
    """
  end

  defp label(:podcast), do: gettext("Podcasts")
  defp label(:youtube), do: "YouTube"
  defp label(:peertube), do: "PeerTube"
  defp label(:mediathek), do: gettext("Mediathek")
end
