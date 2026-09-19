defmodule SikioWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SikioWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"
  alias Ithibati.Schema.Identifier

  @doc """
  The element the passkey hook attaches to.

  It renders nothing — it exists so the hook has somewhere to live and somewhere to read the four
  ceremony paths from, which are yours because you chose the scope `ithibati_routes/1` is mounted
  under. Both pages here that can start a ceremony render it, so the paths are written once: a
  second copy is a second place to forget when that scope moves.
  """
  def passkey_ceremony(assigns) do
    ~H"""
    <div
      id="passkey"
      phx-update="ignore"
      phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
      data-registration-challenge-url={~p"/auth/registration/challenge"}
      data-registration-url={~p"/auth/registration"}
      data-authentication-challenge-url={~p"/auth/authentication/challenge"}
      data-recovery-url={~p"/auth/recovery"}
      data-authentication-url={~p"/auth/authentication"}
    >
    </div>
    """
  end

  @doc """
  What an identifier may look like, for the browser to check before the server does.

  Derived from `Ithibati.Schema.Identifier.username_format/0` rather than written out beside it: an
  HTML `pattern` that disagrees with the server refuses names the server would take, or waves
  through names it will not, and nothing says so. The anchors come off because `pattern` is
  implicitly anchored and its grammar has no `\\A`.
  """
  def username_pattern do
    Identifier.username_format()
    |> Regex.source()
    |> String.replace(["\\A", "\\z"], "")
  end

  @doc "The name, with the full stop that carries the accent. Written once, rendered in both shells."
  def wordmark(assigns) do
    ~H"""
    sikio<span class="text-orange-600 dark:text-orange-400">.</span>
    """
  end

  @doc "A compact, shared layout for authentication and first-account setup."
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="relative isolate min-h-svh">
      <div
        aria-hidden="true"
        class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[85svh] bg-[radial-gradient(ellipse_at_top,var(--color-teal-100),transparent_70%)] dark:bg-[radial-gradient(ellipse_at_top,var(--color-teal-950),transparent_70%)]"
      />
      <main id="auth-main" class="flex min-h-svh items-center justify-center px-6 py-20">
        <div class="w-full max-w-sm">
          <p
            id="project-name"
            class="mb-3 text-center font-display text-4xl tracking-tight text-teal-800 break-words dark:text-teal-300"
          >
            <.wordmark />
          </p>
          <p class="mb-10 text-center text-xs tracking-widest text-stone-500 uppercase dark:text-stone-400">
            {gettext("Your time. Your queue.")}
          </p>
          <div :if={@title} class="mb-8 text-center">
            <h1 class="text-xl font-semibold tracking-tight">{@title}</h1>
            <p :if={@subtitle} class="mt-2 text-sm leading-6 text-stone-600 dark:text-stone-400">
              {@subtitle}
            </p>
          </div>
          {render_slot(@inner_block)}
        </div>
      </main>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc "The primary action on an authentication screen."
  attr :rest, :global, include: ~w(type disabled name value)
  slot :inner_block, required: true

  def auth_button(assigns) do
    ~H"""
    <button
      class="inline-flex w-full cursor-pointer items-center justify-center gap-2 rounded-full bg-teal-800 px-4 py-3 text-sm font-semibold text-white shadow-sm transition hover:bg-teal-900 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-600 disabled:cursor-not-allowed disabled:opacity-50 dark:bg-teal-600 dark:hover:bg-teal-500"
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "The signed-in application shell."
  attr :flash, :map, required: true
  attr :current_account, :map, required: true
  slot :inner_block, required: true

  def member(assigns) do
    ~H"""
    <div class="min-h-svh">
      <header class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-4 px-6 py-5 sm:px-12 sm:py-7">
        <.link navigate={~p"/"} class="flex items-center gap-3" aria-label={gettext("Sikio home")}>
          <span class="flex size-10 items-center justify-center rounded-full bg-teal-800 text-white dark:bg-teal-600">
            <Lucideicons.play aria-hidden="true" class="size-4 fill-current" />
          </span>
          <span class="font-display text-2xl tracking-tight"><.wordmark /></span>
        </.link>
        <nav
          class="flex w-full flex-wrap items-center gap-x-5 gap-y-1 text-sm sm:w-auto sm:justify-end"
          aria-label={gettext("Main navigation")}
        >
          <.link id="library-link" navigate={~p"/"} class="inline-flex min-h-11 items-center">
            {gettext("Library")}
          </.link>
          <.link
            id="subscriptions-link"
            navigate={~p"/subscriptions"}
            class="inline-flex min-h-11 items-center"
          >
            {gettext("Subscriptions")}
          </.link>
          <.link
            id="invitations-link"
            navigate={~p"/invitations"}
            class="inline-flex min-h-11 items-center"
          >
            {gettext("Invitations")}
          </.link>
          <details
            id="user-menu"
            class="relative shrink-0"
            phx-click-away={JS.remove_attribute("open", to: "#user-menu")}
            phx-window-keydown={JS.remove_attribute("open", to: "#user-menu")}
            phx-key="Escape"
          >
            <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-lg text-sm font-semibold focus-visible:outline-2 focus-visible:outline-teal-600">
              <span class="max-w-32 truncate" title={@current_account.username}>{@current_account.username}</span><Lucideicons.chevron_down
                aria-hidden="true"
                class="size-4 shrink-0 transition"
              />
            </summary>
            <nav
              aria-label={gettext("Your account")}
              class="absolute right-0 z-20 mt-2 w-56 rounded-xl border border-stone-200 bg-white p-2 shadow-lg dark:border-stone-700 dark:bg-stone-900"
            >
              <.link
                navigate={~p"/account/passkeys"}
                class="block rounded-lg px-3 py-2 text-sm hover:bg-stone-100 dark:hover:bg-stone-800"
              >{gettext("Manage passkeys")}</.link>
              <.link
                navigate={~p"/account/recovery-codes"}
                class="block rounded-lg px-3 py-2 text-sm hover:bg-stone-100 dark:hover:bg-stone-800"
              >{gettext("Recovery codes")}</.link>
              <.link
                href={~p"/session"}
                method="delete"
                class="mt-1 block rounded-lg border-t border-stone-100 px-3 py-2 text-sm text-red-700 hover:bg-red-50 dark:border-stone-800 dark:text-red-400 dark:hover:bg-stone-800"
              >{gettext("Sign out")}</.link>
            </nav>
          </details>
        </nav>
      </header>
      <main id="main-content" class="mx-auto min-h-[75vh] max-w-7xl px-6 py-12 sm:px-12 sm:py-20">
        {render_slot(@inner_block)}
      </main>
      <footer class="mx-auto flex max-w-7xl flex-wrap justify-between gap-3 border-t border-stone-200 px-6 py-7 text-xs text-stone-500 sm:px-12 dark:border-stone-800 dark:text-stone-400">
        <span>{gettext("A little more intention. A little less autoplay.")}</span>
        <span>{gettext("Sikio · Your personal media library")}</span>
      </footer>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <Lucideicons.loader_circle aria-hidden="true" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <Lucideicons.loader_circle aria-hidden="true" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
