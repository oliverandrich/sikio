# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTransferLive do
  @moduledoc """
  Exports the account's library and imports one exported elsewhere.

  The upload is checked at once. The import itself runs as `Sikio.Library.TransferImport`,
  because fetching every source takes minutes. Its summary arrives here if the page is open.
  """
  use SikioWeb, :live_view

  alias Sikio.Library.Events
  alias Sikio.Library.Transfer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe_imports(socket.assigns.current_account)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Move your library"),
       form: to_form(%{}),
       started: false,
       error: nil,
       summary: nil
     )
     |> allow_upload(:library, accept: ~w(.json), max_entries: 1, max_file_size: 5_000_000)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, error: nil)}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :library, ref)}

  def handle_event("import", _params, socket) do
    account = socket.assigns.current_account

    case consume_uploaded_entries(socket, :library, fn %{path: path}, _entry ->
           {:ok, start(account, path)}
         end) do
      [{:ok, _job}] -> {:noreply, assign(socket, started: true, summary: nil, error: nil)}
      [{:error, reason}] -> {:noreply, assign(socket, error: message(reason))}
      [] -> {:noreply, assign(socket, error: gettext("Choose one file and wait for its upload."))}
    end
  end

  @impl true
  def handle_info({:library_imported, {:ok, summary}}, socket),
    do: {:noreply, assign(socket, started: false, summary: summary)}

  def handle_info({:library_imported, :error}, socket),
    do:
      {:noreply,
       assign(socket,
         started: false,
         error:
           gettext(
             "The import stopped. What it added so far stays; importing the file again adds the rest."
           )
       )}

  # The layout's hook passes on library events that concern the lists, not this page.
  def handle_info(_event, socket), do: {:noreply, socket}

  # LiveView creates this temporary path on the server. It never comes from form params.
  # sobelow_skip ["Traversal.FileModule"]
  defp start(account, path), do: Transfer.start(account, File.read!(path))

  defp message(:already_running),
    do: gettext("An import is already running. Its result appears here when it finishes.")

  defp message(:too_large), do: gettext("Choose a file smaller than 5 MB.")

  defp message(:too_many_subscriptions),
    do: gettext("This file lists more than 500 sources, more than one import handles.")

  defp message(:too_many_entries),
    do: gettext("This file lists more than 20,000 episodes, more than one import handles.")

  defp message(_reason), do: gettext("This is not a library exported from Sikio.")

  defp upload_error(:too_large), do: gettext("File exceeds 5 MB.")
  defp upload_error(:too_many_files), do: gettext("Choose one file at a time.")
  defp upload_error(:not_accepted), do: gettext("Choose a .json file.")
  defp upload_error(_), do: gettext("Upload failed. Please try again.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:subscriptions}
      title={gettext("Move your library")}
      back={%{to: ~p"/subscriptions", label: gettext("Subscriptions")}}
    >
      <%!-- Hidden below `lg`. On phones the layout's top bar has the back link. --%>
      <.link
        navigate={~p"/subscriptions"}
        class="hidden text-label font-semibold text-accent lg:inline"
      >{gettext("← Your subscriptions")}</.link>
      <header class="mx-auto max-w-2xl pt-4 pb-4 text-center sm:pt-10">
        <h1 data-large-title class="text-title font-semibold">
          {gettext("Take your library along.")}
        </h1>
        <p class="mt-2 text-muted">
          {gettext(
            "Export your sources, tags, queue, history, favourites and settings, and import them on another Sikio."
          )}
        </p>
      </header>
      <section class="mx-auto mt-8 max-w-2xl">
        <.link
          id="library-export-link"
          href={~p"/library.json"}
          class="inline-flex min-h-11 items-center gap-1 font-semibold text-link"
        >
          {gettext("Export my library")}
          <Lucideicons.download aria-hidden="true" class="size-4" />
        </.link>
        <.form
          for={@form}
          id="library-upload-form"
          class="mt-8"
          phx-change="validate"
          phx-submit="import"
        >
          <%!-- The label is the click and drop area. The input is `sr-only` but focusable. --%>
          <label
            id="library-drop"
            for={@uploads.library.ref}
            phx-drop-target={@uploads.library.ref}
            class="flex min-h-32 cursor-pointer flex-col items-center justify-center gap-2 rounded-control border-2 border-dashed border-edge p-6 text-center hover:border-ink has-focus-visible:border-ink has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-accent [&.phx-drop-target-active]:border-signal"
          >
            <Lucideicons.upload aria-hidden="true" class="size-5 text-muted" />
            <span class="font-semibold text-link">{gettext("Choose an exported library")}</span>
            <span class="text-label text-muted">{gettext("or drop it here")}</span>
            <.live_file_input upload={@uploads.library} class="sr-only" />
          </label>
          <div :for={entry <- @uploads.library.entries} id={"library-file-#{entry.ref}"} class="mt-3">
            <div class="flex items-center gap-3">
              <Lucideicons.file_text aria-hidden="true" class="size-4 shrink-0 text-muted" />
              <p class="min-w-0 flex-1 text-label break-all">
                {entry.client_name}
                <span class="text-muted">· {file_size(entry.client_size)}</span>
              </p>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="min-h-11 cursor-pointer text-label text-link"
              >{gettext("Remove file")}</button>
            </div>
            <p
              :for={error <- upload_errors(@uploads.library, entry)}
              role="alert"
              class="mt-2 text-label text-danger"
            >
              {upload_error(error)}
            </p>
          </div>
          <p class="mt-3 text-meta leading-relaxed text-muted">
            {gettext(
              "Sikio fetches every source again. Your current library stays: the import adds to it and changes nothing you already have. Episodes no longer in their feed come back when queued, started, starred or saved."
            )}
          </p>
          <.button class="mt-5" variant="primary" disabled={@uploads.library.entries == []}>
            {gettext("Import library")}
          </.button>
        </.form>
      </section>
      <p
        :if={@error}
        id="library-error"
        role="alert"
        class="mx-auto mt-6 max-w-2xl rounded-control bg-danger-surface p-4 text-label text-danger"
      >
        {@error}
      </p>
      <p
        :if={@started}
        id="library-started"
        role="status"
        class="mx-auto mt-6 max-w-2xl rounded-control bg-selection p-4 text-label text-ink"
      >
        {gettext(
          "Import started. Sikio fetches your sources now. You can leave this page; the result appears here while it is open."
        )}
      </p>
      <div
        :if={@summary}
        id="library-summary"
        role="status"
        class="mx-auto mt-6 max-w-2xl rounded-control bg-selection p-4 text-label text-ink"
      >
        <p>
          {gettext("%{imported} sources imported · %{existing} already followed · %{failed} failed",
            imported: @summary.subscriptions.imported,
            existing: @summary.subscriptions.existing,
            failed: length(@summary.subscriptions.failed)
          )}
        </p>
        <p class="mt-1">
          {gettext("%{restored} episodes restored · %{kept} kept as they were · %{missing} not found",
            restored: @summary.entries.restored,
            kept: @summary.entries.kept,
            missing: @summary.entries.missing
          )}
        </p>
        <ul :if={@summary.subscriptions.failed != []} id="library-failed" class="mt-3 text-muted">
          <li :for={url <- @summary.subscriptions.failed} class="break-all">{url}</li>
        </ul>
      </div>
    </Layouts.member>
    """
  end
end
