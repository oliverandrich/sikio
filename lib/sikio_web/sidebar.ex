# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar do
  @moduledoc """
  Sidebar data: subscribed sources, tags and item counts per view.

  It is an `on_mount` hook of the `:members` live_session, so every member page has the sidebar.
  `SikioWeb.LibraryEvents` refreshes it on library events.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Sikio.Library
  alias Sikio.Tags
  alias SikioWeb.MediaComponents

  def on_mount(:default, _params, _session, socket), do: {:cont, refresh(socket)}

  @doc "Reloads the counts, sources and tags into the `:sidebar` assign."
  def refresh(socket) do
    account = socket.assigns.current_account

    sources =
      account
      |> Library.subscriptions()
      |> Enum.sort_by(&String.downcase(MediaComponents.source_name(&1) || ""))

    tags = Tags.list(account)

    # Titles for the slugs that URLs append to source and tag ids.
    titles =
      Map.new(sources, &{&1.feed_id, MediaComponents.source_name(&1)})
      |> Map.merge(Map.new(tags, &{{:tag, &1.id}, &1.name}))

    assign(socket, :sidebar, %{
      counts: Library.counts(account),
      sources: sources,
      tags: tags,
      tag_feeds: Tags.feeds(account),
      titles: titles
    })
  end
end
