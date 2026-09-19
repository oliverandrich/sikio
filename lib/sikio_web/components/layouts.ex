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

  @doc "A compact, shared layout for authentication and first-account setup."
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="relative isolate min-h-svh bg-white text-zinc-950 dark:bg-zinc-950 dark:text-zinc-100">
      <div
        aria-hidden="true"
        class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[85svh] bg-[radial-gradient(ellipse_at_top,var(--color-violet-100),transparent_70%)] dark:bg-[radial-gradient(ellipse_at_top,var(--color-violet-950),transparent_70%)]"
      />
      <main id="auth-main" class="flex min-h-svh items-center justify-center px-6 py-20">
        <div class="w-full max-w-sm">
          <p
            id="project-name"
            class="mb-10 text-center text-4xl font-semibold tracking-tight text-violet-600 break-words dark:text-violet-400"
          >
            Sikio
          </p>
          <div :if={@title} class="mb-8 text-center">
            <h1 class="text-xl font-semibold tracking-tight">{@title}</h1>
            <p :if={@subtitle} class="mt-2 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
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
      class="inline-flex w-full cursor-pointer items-center justify-center gap-2 rounded-lg bg-violet-600 px-4 py-3 text-sm font-semibold text-white shadow-sm transition hover:bg-violet-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-violet-500 disabled:cursor-not-allowed disabled:opacity-50 dark:bg-violet-500 dark:hover:bg-violet-400"
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
    <div class="min-h-svh bg-zinc-50 dark:bg-zinc-950">
      <header class="border-b border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950">
        <div class="flex items-center justify-between gap-4 px-6 py-5">
          <.link
            navigate={~p"/"}
            class="min-w-0 truncate text-xl font-semibold tracking-tight text-violet-600 dark:text-violet-400"
          >Sikio</.link>
          <details
            id="user-menu"
            class="group relative shrink-0"
            phx-click-away={JS.remove_attribute("open", to: "#user-menu")}
            phx-window-keydown={JS.remove_attribute("open", to: "#user-menu")}
            phx-key="Escape"
          >
            <summary class="flex cursor-pointer list-none items-center gap-2 rounded-lg px-3 py-2 text-sm font-semibold hover:bg-zinc-100 focus-visible:outline-2 focus-visible:outline-violet-500 dark:hover:bg-zinc-800">
              <span class="max-w-32 truncate" title={@current_account.username}>{@current_account.username}</span><Lucideicons.chevron_down
                aria-hidden="true"
                class="size-4 shrink-0 transition"
              />
            </summary>
            <nav
              aria-label={gettext("Your account")}
              class="absolute right-0 z-20 mt-2 w-56 rounded-xl border border-zinc-200 bg-white p-2 shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
            >
              <.link
                navigate={~p"/account/passkeys"}
                class="block rounded-lg px-3 py-2 text-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >{gettext("Manage passkeys")}</.link>
              <.link
                navigate={~p"/account/recovery-codes"}
                class="block rounded-lg px-3 py-2 text-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >{gettext("Recovery codes")}</.link>
              <.link
                href={~p"/session"}
                method="delete"
                class="mt-1 block rounded-lg border-t border-zinc-100 px-3 py-2 text-sm text-red-700 hover:bg-red-50 dark:border-zinc-800 dark:text-red-400 dark:hover:bg-zinc-800"
              >{gettext("Sign out")}</.link>
            </nav>
          </details>
        </div>
      </header>
      <main class="mx-auto max-w-3xl px-6 py-12 sm:py-20">{render_slot(@inner_block)}</main>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-4 border-b border-zinc-200 px-4 py-4 dark:border-zinc-800 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" alt="Phoenix" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-wrap items-center gap-3 px-1">
          <li>
            <a
              href="https://phoenixframework.org/"
              class="rounded-md px-3 py-2 text-sm font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600 dark:focus-visible:outline-indigo-400"
            >Website</a>
          </li>
          <li>
            <a
              href="https://github.com/phoenixframework/phoenix"
              class="rounded-md px-3 py-2 text-sm font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600 dark:focus-visible:outline-indigo-400"
            >GitHub</a>
          </li>
          <li>
            <a
              href="https://phoenix.hexdocs.pm/overview.html"
              class="inline-flex items-center justify-center gap-2 rounded-md px-4 py-2 text-sm font-semibold transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600 dark:focus-visible:outline-indigo-400 bg-indigo-600 text-white hover:bg-indigo-700 dark:bg-indigo-500 dark:hover:bg-indigo-400"
            >
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
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
