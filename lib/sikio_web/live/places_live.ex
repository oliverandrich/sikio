# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlacesLive do
  @moduledoc """
  The Library page: every place of the library as a grouped list, in the manner of an iPhone's
  settings. A phone moves through it where a wide screen has the sidebar: the views, the tags
  and the subscriptions, each leading to its list. The places and their counts come from
  `SikioWeb.Sidebar`, which keeps them current.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents, only: [views: 0, view_icon: 1, source_name: 1]

  alias Sikio.Library
  alias SikioWeb.Sidebar

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: gettext("Library"))}

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :counts,
        Library.tally(assigns.sidebar.counts, %{}, assigns.sidebar.tag_feeds)
      )

    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      counts={@counts}
      section={:places}
      title={gettext("Library")}
    >
      <h1 data-large-title class="mb-6 text-title font-semibold">{gettext("Library")}</h1>
      <.places id="places-views">
        <.place
          :for={{status, key, label} <- views()}
          :if={key not in [:inbox, :queue]}
          to={Sidebar.place_path("status", status)}
          count={if(key == :all, do: @counts[key], else: 0)}
        >
          <:icon><.view_icon view={key} class="size-5 text-muted" /></:icon>
          {label}
        </.place>
      </.places>
      <.places :if={@sidebar.tags != []} id="places-tags" heading={gettext("Tags")}>
        <.place
          :for={tag <- @sidebar.tags}
          to={Sidebar.place_path("tag", to_string(tag.id), @sidebar.titles)}
          count={Map.get(@counts.tags, tag.id, 0)}
        >
          {tag.name}
        </.place>
      </.places>
      <.places :if={@sidebar.sources != []} id="places-sources" heading={gettext("Subscriptions")}>
        <.place
          :for={source <- @sidebar.sources}
          to={Sidebar.place_path("source", to_string(source.feed_id), @sidebar.titles)}
          count={Map.get(@counts.sources, source.feed_id, 0)}
        >
          {source_name(source)}
        </.place>
      </.places>
    </Layouts.member>
    """
  end

  attr :id, :string, required: true
  attr :heading, :string, default: nil
  slot :inner_block, required: true

  # A group of places, set apart as an iPhone sets apart a group of settings.
  defp places(assigns) do
    ~H"""
    <section id={@id} class="mb-6" aria-label={@heading}>
      <h2
        :if={@heading}
        class="mb-2 px-4 text-meta font-semibold tracking-wider text-muted uppercase"
      >
        {@heading}
      </h2>
      <nav class="flex flex-col divide-y divide-line overflow-hidden rounded-2xl bg-surface ring-1 ring-line">
        {render_slot(@inner_block)}
      </nav>
    </section>
    """
  end

  attr :to, :string, required: true
  attr :count, :integer, required: true
  slot :icon
  slot :inner_block, required: true

  defp place(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="flex min-h-12 items-center gap-3 px-4 text-body text-ink hover:bg-ground"
    >
      {render_slot(@icon)}
      <span class="min-w-0 grow truncate">{render_slot(@inner_block)}</span>
      <span :if={@count > 0} class="font-mono text-meta text-muted">{@count}</span>
      <Lucideicons.chevron_right aria-hidden="true" class="size-4 shrink-0 text-muted" />
    </.link>
    """
  end
end
