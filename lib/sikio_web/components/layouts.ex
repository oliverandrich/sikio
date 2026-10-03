# SPDX-License-Identifier: AGPL-3.0-or-later

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

  @doc """
  The offer section 13 obliges a deployment to make, in the two shells anybody ever sees.

  Read at render rather than at compile time, because `SOURCE_URL` is what a deployment that
  modified Sikio sets, and it is read after this is compiled.
  """
  attr :class, :any, default: "underline underline-offset-2"

  def source_offer(assigns) do
    ~H"""
    <a href={Application.get_env(:sikio, :source_url)} class={@class}>
      {gettext("Source code")}
    </a>
    """
  end

  @doc "The name, with the dot that carries the signal. Written once, rendered in both shells."
  def wordmark(assigns) do
    ~H"""
    sikio<span
      aria-hidden="true"
      class="ml-[0.12em] inline-block size-[0.28em] rounded-full bg-signal align-baseline ring-[0.1em] ring-signal/25"
    ></span>
    """
  end

  @doc "A compact, shared layout for authentication and first-account setup."
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div>
      <main id="auth-main" class="flex min-h-svh items-center justify-center px-6 py-20">
        <div class="w-full max-w-sm">
          <p
            id="project-name"
            class="mb-3 text-center text-4xl font-semibold tracking-tight break-words"
          >
            <.wordmark />
          </p>
          <p class="mb-10 text-center text-label text-muted">
            {gettext("Your time. Your queue.")}
          </p>
          <div :if={@title} class="mb-8 text-center">
            <h1 class="text-title font-semibold">{@title}</h1>
            <p :if={@subtitle} class="mt-2 text-muted">
              {@subtitle}
            </p>
          </div>
          {render_slot(@inner_block)}
          <p class="mt-10 text-center text-meta text-muted">
            <.source_offer />
          </p>
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
      class="inline-flex min-h-11 w-full cursor-pointer items-center justify-center gap-2 rounded-control bg-accent px-4 py-2 text-label font-semibold text-on-accent transition hover:bg-accent/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-50"
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  The signed-in application shell.

  Below `lg` the header is a bar across the top. From `lg` the same element is the reader's left
  column, so every link exists once in the page. The library's views and sources appear in it
  when `sidebar` is given, which `SikioWeb.Sidebar` assigns on every member page. Each is a place
  of its own; choosing one lets go of the others.
  """
  attr :flash, :map, required: true
  attr :current_account, :map, required: true
  attr :sidebar, :map, default: nil, doc: "counts and sources from `SikioWeb.Sidebar`"
  attr :filters, :map, default: %{}, doc: "the library filters in force, to mark the active view"
  attr :patch, :boolean, default: false, doc: "whether sidebar links patch, as in the library"

  attr :counts, :map,
    default: nil,
    doc: "how much each place holds, when the page has counted already"

  attr :section, :atom,
    default: nil,
    values: [nil, :library, :subscriptions, :invitations, :account],
    doc: "where the reader is, to mark it in the navigation"

  attr :bleed, :boolean,
    default: false,
    doc: "whether the page lays out its own columns edge to edge, as the library does"

  slot :inner_block, required: true

  def member(assigns) do
    counts =
      assigns.counts ||
        (assigns.sidebar && Sikio.Library.tally(assigns.sidebar.counts, %{}))

    assigns = assign(assigns, :counts, counts)

    ~H"""
    <div class="min-h-svh pb-[calc(var(--nav-bar)+env(safe-area-inset-bottom))] lg:grid lg:grid-cols-[256px_minmax(0,1fr)] lg:pb-0">
      <%!-- assets/js/dock_place.mjs makes room at its foot for the now playing bar. --%>
      <header
        phx-mounted={JS.ignore_attributes("style")}
        class="flex flex-wrap items-center justify-between gap-4 px-6 py-5 sm:px-12 sm:py-7 lg:sticky lg:top-0 lg:h-svh lg:flex-col lg:flex-nowrap lg:items-stretch lg:justify-start lg:gap-5 lg:overflow-y-auto lg:border-r lg:border-line lg:px-3 lg:py-4"
      >
        <.link
          navigate={~p"/"}
          class="flex items-center gap-3 lg:px-2.5"
          aria-label={gettext("Sikio home")}
        >
          <span class="text-[30px] leading-none font-bold tracking-tight"><.wordmark /></span>
        </.link>
        <div
          :if={@sidebar}
          id="sidebar"
          class="hidden flex-col gap-5 lg:-mx-3 lg:flex lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:px-3 lg:py-1"
        >
          <nav aria-label={gettext("Views")} class="flex flex-col gap-0.5">
            <.sidebar_link
              :for={{status, key, label} <- SikioWeb.MediaComponents.views()}
              id={"view-#{key}"}
              to={SikioWeb.Sidebar.place_path("status", status)}
              patch={@patch}
              active={@patch and SikioWeb.Sidebar.place?(@filters, "status", status)}
              count={@counts[key]}
            >
              {label}
            </.sidebar_link>
          </nav>
          <nav aria-labelledby="sources-heading" class="flex flex-col gap-0.5">
            <div class="flex items-center justify-between pb-1">
              <h2 id="sources-heading" class="text-meta">
                <.link
                  id="subscriptions-heading"
                  navigate={~p"/subscriptions"}
                  aria-current={@section == :subscriptions && "page"}
                  class="flex min-h-7 items-center rounded-control px-2.5 font-semibold tracking-wider text-muted uppercase hover:text-ink aria-[current=page]:text-accent"
                >
                  {gettext("Subscriptions")}
                </.link>
              </h2>
              <.link
                navigate={~p"/subscriptions"}
                aria-label={gettext("Add a source")}
                class="flex size-7 items-center justify-center rounded-control text-muted hover:bg-surface"
              >
                <Lucideicons.plus aria-hidden="true" class="size-4" />
              </.link>
            </div>
            <.sidebar_link
              :for={source <- @sidebar.sources}
              id={"source-#{source.feed_id}"}
              to={SikioWeb.Sidebar.place_path("source", to_string(source.feed_id), @sidebar.titles)}
              patch={@patch}
              active={
                @patch and SikioWeb.Sidebar.place?(@filters, "source", to_string(source.feed_id))
              }
              count={Map.get(@counts.sources, source.feed_id, 0)}
              problem={
                source.feed.last_error &&
                  SikioWeb.MediaComponents.refresh_problem(source.feed.last_error)
              }
            >
              <:mark>
                <img
                  :if={source.feed.icon_url}
                  src={
                    SikioWeb.Pictures.path(
                      [source.feed.icon_url],
                      SikioWeb.MediaComponents.kind_mark(source.feed)
                    )
                  }
                  alt=""
                  loading="lazy"
                  class="size-5 shrink-0 rounded-full bg-line object-cover"
                />
                <.initial :if={!source.feed.icon_url} name={source.feed.title} />
              </:mark>
              {source.feed.title}
            </.sidebar_link>
          </nav>
        </div>
        <nav
          id="main-navigation"
          class="fixed inset-x-0 bottom-0 z-30 flex min-h-[var(--nav-bar)] items-center justify-around border-t border-line bg-ground pb-[env(safe-area-inset-bottom)] text-label font-semibold lg:static lg:mt-auto lg:flex-col lg:items-stretch lg:justify-start lg:gap-0.5 lg:bg-transparent lg:pt-3 lg:pb-0 lg:font-normal"
          aria-label={gettext("Main navigation")}
        >
          <.link
            id="library-link"
            aria-current={@section == :library && "page"}
            navigate={~p"/"}
            class={[nav_link_class(), "lg:hidden"]}
          >
            {gettext("Library")}
          </.link>
          <.link
            id="subscriptions-link"
            aria-current={@section == :subscriptions && "page"}
            navigate={~p"/subscriptions"}
            class={[nav_link_class(), "lg:hidden"]}
          >
            {gettext("Subscriptions")}
          </.link>
          <details
            id="user-menu"
            data-active={@section in [:account, :invitations]}
            class="relative shrink-0"
            phx-click-away={JS.remove_attribute("open", to: "#user-menu")}
            phx-window-keydown={JS.remove_attribute("open", to: "#user-menu")}
            phx-key="Escape"
          >
            <summary class={[
              "flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-control px-2 focus-visible:outline-2 focus-visible:outline-accent lg:min-h-9 lg:px-2.5 lg:hover:bg-surface",
              @section in [:account, :invitations] && "font-semibold text-accent lg:bg-selection"
            ]}>
              <.initial name={@current_account.username} class="hidden lg:flex" /><span
                class="max-w-32 truncate"
                title={@current_account.username}
              >{@current_account.username}</span><Lucideicons.chevron_down
                aria-hidden="true"
                class="size-4 shrink-0 transition"
              />
            </summary>
            <nav
              aria-label={gettext("Your account")}
              class="absolute right-0 bottom-full z-20 mb-2 w-56 rounded-control border border-line bg-surface p-1 font-normal shadow-lg lg:right-auto lg:left-0"
            >
              <.link
                id="invitations-link"
                navigate={~p"/invitations"}
                aria-current={@section == :invitations && "page"}
                class="block rounded-control px-3 py-2 hover:bg-ground aria-[current=page]:font-semibold aria-[current=page]:text-accent"
              >{gettext("Invitations")}</.link>
              <.link
                navigate={~p"/account/passkeys"}
                class="block rounded-control px-3 py-2 hover:bg-ground"
              >{gettext("Manage passkeys")}</.link>
              <.link
                navigate={~p"/account/recovery-codes"}
                class="block rounded-control px-3 py-2 hover:bg-ground"
              >{gettext("Recovery codes")}</.link>
              <.source_offer class="block rounded-control px-3 py-2 hover:bg-ground" />
              <.link
                href={~p"/session"}
                method="delete"
                class="mt-1 block rounded-control border-t border-line px-3 py-2 text-danger hover:bg-danger-surface"
              >{gettext("Sign out")}</.link>
            </nav>
          </details>
        </nav>
      </header>
      <div class="min-w-0">
        <main
          id="main-content"
          class={[
            "min-h-[75vh]",
            !@bleed && "mx-auto max-w-7xl px-6 py-6 sm:px-12 sm:py-12 lg:max-w-none lg:px-10 lg:py-10"
          ]}
        >
          {render_slot(@inner_block)}
        </main>
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :to, :string, required: true
  attr :patch, :boolean, required: true
  attr :active, :boolean, required: true
  attr :count, :integer, required: true
  attr :problem, :string, default: nil, doc: "what went wrong with the source, if anything"
  slot :mark, doc: "a picture or an initial before the name"
  slot :inner_block, required: true

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch && @to}
      navigate={!@patch && @to}
      aria-current={@active && "page"}
      class={[
        "flex min-h-9 items-center justify-between gap-2 rounded-control px-2.5 text-label",
        @active && "bg-selection font-semibold text-accent",
        !@active && "hover:bg-surface"
      ]}
    >
      <span class="flex min-w-0 items-center gap-2.5">
        {render_slot(@mark)}
        <span class="min-w-0 truncate">{render_slot(@inner_block)}</span>
        <span :if={@problem} data-problem title={@problem} class="shrink-0 text-warning">
          <Lucideicons.zap aria-hidden="true" class="size-3.5 fill-current" />
          <span class="sr-only">{@problem}</span>
        </span>
      </span>
      <span
        :if={@count > 0}
        id={"#{@id}-count"}
        class={[
          "-mr-1.5 rounded-full px-1.5 font-mono text-meta font-normal",
          @active && "bg-accent/15",
          !@active && "text-muted"
        ]}
      >
        {@count}
      </span>
    </.link>
    """
  end

  attr :name, :string, required: true
  attr :class, :any, default: nil

  # A name's first letter in a tinted circle, where no picture stands for it.
  defp initial(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-initial
      class={[
        "size-5 shrink-0 items-center justify-center rounded-full bg-accent/15 text-[11px] font-semibold text-accent",
        @class || "flex"
      ]}
    >
      {SikioWeb.MediaComponents.initial(@name)}
    </span>
    """
  end

  defp nav_link_class,
    do:
      "inline-flex min-h-11 items-center px-2 aria-[current=page]:text-accent lg:min-h-9 lg:rounded-control lg:px-2.5 lg:hover:bg-surface aria-[current=page]:font-semibold lg:aria-[current=page]:bg-selection"

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
