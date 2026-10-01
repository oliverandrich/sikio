# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.OPMLLive do
  @moduledoc """
  Imports an OPML subscription list, showing what it holds before anything is subscribed.

  The preview is the point. An OPML file from another application may name fifty feeds, some of
  them long dead, and the list of what will be attempted is worth seeing first. The import then
  reports one line per source rather than a single pass or fail.
  """
  use SikioWeb, :live_view

  alias Sikio.Library
  alias Sikio.Library.OPML

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Import subscriptions"),
       form: to_form(%{}),
       pending: [],
       busy: false,
       error: nil,
       summary: nil
     )
     |> allow_upload(:opml, accept: ~w(.opml .xml), max_entries: 1, max_file_size: 1_000_000)
     |> stream(:sources, [])}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("validate", _params, socket) do
    {:noreply,
     socket |> assign(pending: [], summary: nil, error: nil) |> stream(:sources, [], reset: true)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :opml, ref)}

  def handle_event("preview", _params, socket) do
    case uploaded_entries(socket, :opml) do
      {[_], []} ->
        [result] =
          consume_uploaded_entries(socket, :opml, fn %{path: path}, _entry ->
            {:ok, read_upload(path)}
          end)

        preview(socket, result)

      _ ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Choose one OPML file and wait for its upload to finish.")
         )}
    end
  end

  def handle_event("import", _params, socket) do
    sources = socket.assigns.pending
    account = socket.assigns.current_account

    if sources == [] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(busy: true, error: nil, framed: Library.player_origins(account))
       |> start_async(:import, fn -> OPML.import_sources(account, sources) end)}
    end
  end

  @impl true
  def handle_async(:import, {:ok, results}, socket) do
    counts = Enum.frequencies_by(results, & &1.status)
    framed = socket.assigns.framed

    summary =
      gettext("%{imported} imported · %{existing} already subscribed · %{failed} failed",
        imported: counts[:imported] || 0,
        existing: counts[:existing] || 0,
        failed: counts[:failed] || 0
      )

    socket = socket |> assign(busy: false, pending: [], summary: summary) |> show_sources(results)

    # An instance imported here may now be played, and what may be framed is decided on a
    # document. Moving inside a LiveView produces none, so this asks for one.
    if Library.player_origins(socket.assigns.current_account) == framed,
      do: {:noreply, socket},
      else: {:noreply, redirect(socket, to: ~p"/subscriptions/import")}
  end

  def handle_async(:import, {:exit, _}, socket) do
    {:noreply,
     assign(socket,
       busy: false,
       error: gettext("Import stopped. Sources already added are safe; you can retry the list.")
     )}
  end

  # LiveView supplies this server-created temporary path; it is never taken from form params.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_upload(path), do: path |> File.read!() |> OPML.parse()

  defp preview(socket, {:ok, sources}),
    do:
      {:noreply,
       socket |> assign(pending: sources, error: nil, summary: nil) |> show_sources(sources)}

  defp preview(socket, {:error, reason}),
    do: {:noreply, assign(socket, pending: [], error: message(reason))}

  defp show_sources(socket, sources) do
    rows =
      sources
      |> Enum.with_index()
      |> Enum.map(fn {source, index} -> Map.put(source, :id, index) end)

    stream(socket, :sources, rows, reset: true)
  end

  defp message(:too_large), do: gettext("Choose an OPML file smaller than 1 MB.")

  defp message(:too_many_sources),
    do:
      gettext(
        "Import up to 50 unique sources at a time. Split larger lists into smaller OPML files."
      )

  defp message(:no_sources), do: gettext("This OPML file contains no feed URLs.")
  defp message(_), do: gettext("This is not a valid OPML subscription list.")

  defp result_label(%{status: :imported}), do: gettext("Imported")
  defp result_label(%{status: :existing}), do: gettext("Already subscribed, unchanged")

  defp result_label(%{status: :failed, reason: :unsafe_url}),
    do: gettext("Only public HTTP(S) feed URLs are supported.")

  defp result_label(%{status: :failed}),
    do: gettext("Could not read this feed. Check its URL and try it individually.")

  defp result_label(_), do: gettext("Ready to check")

  defp upload_error(:too_large), do: gettext("File exceeds 1 MB.")
  defp upload_error(:too_many_files), do: gettext("Choose one file at a time.")
  defp upload_error(:not_accepted), do: gettext("Choose an .opml or .xml file.")
  defp upload_error(_), do: gettext("Upload failed. Please try again.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member flash={@flash} current_account={@current_account} sidebar={@sidebar}>
      <.link
        navigate={~p"/subscriptions"}
        class="text-sm font-semibold text-teal-800 dark:text-teal-300"
      >{gettext("← Your subscriptions")}</.link>
      <div class="mt-8">
        <.header>
          {gettext("Bring your favourites.")}
          <:subtitle>
            {gettext("Import podcast and YouTube feed subscriptions from an OPML file.")}
          </:subtitle>
        </.header>
      </div>
      <section class="mt-8 rounded-3xl border border-stone-200 bg-white p-5 sm:p-8 dark:border-stone-800 dark:bg-stone-900">
        <.form for={@form} id="opml-upload-form" phx-change="validate" phx-submit="preview">
          <fieldset disabled={@busy} class="min-w-0">
            <label for={@uploads.opml.ref} class="mb-3 block font-semibold">
              {gettext("OPML file")}
            </label>
            <.live_file_input
              upload={@uploads.opml}
              class="block w-full min-w-0 rounded-xl border border-stone-300 p-3 text-sm dark:border-stone-700"
            />
            <div :for={entry <- @uploads.opml.entries} class="mt-3">
              <p class="text-sm break-all">{entry.client_name} · {entry.progress}%</p>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="min-h-11 text-sm text-teal-800 dark:text-teal-300"
              >{gettext("Remove file")}</button>
              <p
                :for={error <- upload_errors(@uploads.opml, entry)}
                role="alert"
                class="text-sm text-red-800 dark:text-red-300"
              >
                {upload_error(error)}
              </p>
            </div>
            <p
              :for={error <- upload_errors(@uploads.opml)}
              role="alert"
              class="mt-3 text-sm text-red-800 dark:text-red-300"
            >
              {upload_error(error)}
            </p>
            <.button class="mt-5" variant="primary" disabled={@uploads.opml.entries == []}>
              {gettext("Preview sources")}
            </.button>
          </fieldset>
        </.form>
        <p class="mt-5 text-sm leading-relaxed text-stone-500 dark:text-stone-400">
          {gettext(
            "Up to 50 unique feeds and 1 MB per file. Folders are flattened. Existing subscriptions stay unchanged. OPML transfers sources, not playback history or polling settings."
          )}
        </p>
        <.link
          href={~p"/subscriptions.opml"}
          class="mt-4 inline-flex min-h-11 items-center gap-1 font-semibold text-teal-800 dark:text-teal-300"
        >
          {gettext("Export my subscriptions")}
          <Lucideicons.download aria-hidden="true" class="size-4" />
        </.link>
      </section>
      <p
        :if={@error}
        id="opml-error"
        role="alert"
        class="mt-6 rounded-xl bg-red-50 p-4 text-sm text-red-900 dark:bg-red-950 dark:text-red-100"
      >
        {@error}
      </p>
      <p
        :if={@summary}
        id="opml-summary"
        role="status"
        class="mt-6 rounded-xl bg-teal-50 p-4 text-sm text-teal-900 dark:bg-teal-950 dark:text-teal-100"
      >
        {@summary}
      </p>
      <div :if={@pending != []} class="mt-6">
        <.button id="import-opml" variant="primary" phx-click="import" disabled={@busy}>
          {gettext("Import %{count} sources", count: length(@pending))}
        </.button>
        <p :if={@busy} role="status" class="mt-3 text-sm text-stone-600 dark:text-stone-300">
          {gettext(
            "Checking feeds and importing… Keep this page open. Leaving stops the remaining import; completed subscriptions are kept."
          )}
        </p>
      </div>
      <div id="opml-sources" phx-update="stream" class="mt-6 space-y-3">
        <article
          :for={{id, source} <- @streams.sources}
          id={id}
          class="rounded-2xl border border-stone-200 bg-white p-5 dark:border-stone-800 dark:bg-stone-900"
        >
          <h2 class="font-semibold break-words">{source.title}</h2>
          <p class="mt-2 text-xs break-all text-stone-500 dark:text-stone-400">{source.url}</p>
          <p class="mt-3 text-sm text-teal-800 dark:text-teal-300">{result_label(source)}</p>
        </article>
      </div>
    </Layouts.member>
    """
  end
end
