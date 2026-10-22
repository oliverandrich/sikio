# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar do
  @moduledoc """
  Sidebar data: subscribed sources, tags and item counts per view.

  It is an `on_mount` hook of the `:members` live_session, so every member page has the sidebar.
  `SikioWeb.LibraryEvents` refreshes it on library events.
  The hook also handles `show_subscriptions`, the switch between all subscriptions and those
  with new items. `shown` holds the choice from the account's preferences.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Sikio.Library
  alias Sikio.Preferences
  alias Sikio.Tags
  alias SikioWeb.MediaComponents

  def on_mount(:default, _params, _session, socket),
    do: {:cont, socket |> refresh() |> attach_hook(:sidebar, :handle_event, &switched/3)}

  defp switched("show_subscriptions", %{"shown" => shown}, socket) do
    case Preferences.update(socket.assigns.current_account, %{subscriptions_shown: shown}) do
      {:ok, preference} ->
        {:halt, update(socket, :sidebar, &%{&1 | shown: preference.subscriptions_shown})}

      {:error, _changeset} ->
        {:halt, socket}
    end
  end

  defp switched(_event, _params, socket), do: {:cont, socket}

  @doc "Reloads the counts, sources, tags and the subscriptions shown into the `:sidebar` assign."
  def refresh(socket) do
    account = socket.assigns.current_account

    assign(
      socket,
      :sidebar,
      Map.put(load(account), :shown, Preferences.subscriptions_shown(account))
    )
  end

  @doc """
  Returns the subscriptions the lists show, with `counts` from `Sikio.Library.tally/3`.

  Showing new ones lists those with unfinished items. The open source, `open` as a string, and a
  source that failed to refresh stay listed.
  """
  def subscriptions(%{shown: "new", sources: sources}, counts, open) do
    Enum.filter(sources, fn source ->
      Map.get(counts.sources, source.feed_id, 0) > 0 or source.feed.last_error != nil or
        to_string(source.feed_id) == open
    end)
  end

  def subscriptions(%{sources: sources}, _counts, _open), do: sources

  @doc "Returns the account's counts, sources and tags."
  def load(account) do
    sources =
      account
      |> Library.subscriptions()
      |> Enum.sort_by(&String.downcase(MediaComponents.source_name(&1) || ""))

    tags = Tags.list(account)

    # Titles for the slugs that URLs append to source and tag ids.
    titles =
      Map.new(sources, &{&1.feed_id, MediaComponents.source_name(&1)})
      |> Map.merge(Map.new(tags, &{{:tag, &1.id}, &1.name}))

    %{
      counts: Library.counts(account),
      sources: sources,
      tags: tags,
      tag_feeds: Tags.feeds(account),
      titles: titles
    }
  end
end
