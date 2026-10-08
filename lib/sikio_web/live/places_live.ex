# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlacesLive do
  @moduledoc """
  The Library page: views, tags and subscriptions as grouped link lists, styled like iOS settings.
  On a phone it replaces the sidebar. Each entry links to its list.
  Places and counts come from the `sidebar` assign, which `SikioWeb.Sidebar` updates.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents, only: [views: 0, view_icon: 1, source_name: 1]

  alias Sikio.Library
  alias SikioWeb.LibraryPaths

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
      <.group id="places-views" tag="nav">
        <.group_link
          :for={{status, key, label} <- views()}
          :if={key not in [:inbox, :queue]}
          to={LibraryPaths.place_path("status", status)}
          detail={if(key == :all, do: nonzero(@counts[key]))}
        >
          <:icon><.view_icon view={key} class="size-5 text-muted" /></:icon>
          {label}
        </.group_link>
      </.group>
      <.group :if={@sidebar.tags != []} id="places-tags" tag="nav" heading={gettext("Tags")}>
        <.group_link
          :for={tag <- @sidebar.tags}
          to={LibraryPaths.place_path("tag", to_string(tag.id), @sidebar.titles)}
          detail={nonzero(Map.get(@counts.tags, tag.id, 0))}
        >
          {tag.name}
        </.group_link>
      </.group>
      <.group
        :if={@sidebar.sources != []}
        id="places-sources"
        tag="nav"
        heading={gettext("Subscriptions")}
      >
        <:action>
          <.link id="places-manage" navigate={~p"/subscriptions"} class="text-link">
            {gettext("Manage")}
          </.link>
        </:action>
        <.group_link
          :for={source <- @sidebar.sources}
          to={LibraryPaths.place_path("source", to_string(source.feed_id), @sidebar.titles)}
          detail={nonzero(Map.get(@counts.sources, source.feed_id, 0))}
        >
          {source_name(source)}
        </.group_link>
      </.group>
    </Layouts.member>
    """
  end

  # Empty places show no count.
  defp nonzero(0), do: nil
  defp nonzero(count), do: count
end
