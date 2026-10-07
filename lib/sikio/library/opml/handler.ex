# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.OPML.Handler do
  @moduledoc """
  Saxy handler that reads outlines from an OPML document and enforces limits while parsing.

  The file comes from another application, so limits are checked during parsing, not afterwards.
  The limits cover node count, nesting depth, URL length and the number of distinct sources.
  A folder outline tags the sources inside it, and the innermost folder applies.
  A source listed in two folders becomes one source with both tags.
  """
  @behaviour Saxy.Handler

  alias Sikio.Feeds.HTTP

  @impl true
  def handle_event(:start_element, {name, attrs}, state) do
    cond do
      state.nodes >= 1000 or length(state.path) >= 32 -> {:stop, {:error, :invalid_opml}}
      state.path == [] and name != "opml" -> {:stop, {:error, :invalid_opml}}
      true -> start_element(name, Map.new(attrs), state)
    end
  end

  def handle_event(:end_element, _name, %{path: [_ | rest], folders: [_ | folders]} = state),
    do: {:ok, %{state | path: rest, folders: folders}}

  def handle_event(_event, _data, state), do: {:ok, state}

  defp start_element(name, attrs, state) do
    # Each open element pushes its folder name, or nil, so its end element pops it.
    folder =
      if name == "outline" and !is_binary(attrs["xmlUrl"]), do: attrs["text"] || attrs["title"]

    next = %{
      state
      | path: [name | state.path],
        folders: [folder | state.folders],
        nodes: state.nodes + 1,
        body?: state.body? or (name == "body" and state.path == ["opml"])
    }

    if name == "outline" and "body" in state.path and is_binary(attrs["xmlUrl"]) do
      add_source(attrs, next)
    else
      {:ok, next}
    end
  end

  defp source_title(attrs, url), do: String.slice(attrs["text"] || attrs["title"] || url, 0, 512)

  # URLs are normalised before deduplication.
  # Lists often repeat a feed with a different host case or scheme.
  defp add_source(attrs, state) do
    raw = String.trim(attrs["xmlUrl"])

    url =
      case HTTP.normalize(raw) do
        {:ok, uri} -> URI.to_string(uri)
        _ -> raw
      end

    cond do
      byte_size(url) > 2048 or url == "" ->
        {:stop, {:error, :invalid_opml}}

      MapSet.member?(state.seen, url) ->
        {:ok, %{state | sources: Enum.map(state.sources, &tagged(&1, url, folder(state)))}}

      MapSet.size(state.seen) >= 50 ->
        {:stop, {:error, :too_many_sources}}

      true ->
        title = source_title(attrs, url)

        source = tagged(%{title: title, url: url, tags: []}, url, folder(state))
        {:ok, %{state | sources: [source | state.sources], seen: MapSet.put(state.seen, url)}}
    end
  end

  # The innermost enclosing folder name, skipping the current outline's own entry.
  defp folder(%{folders: [_own | around]}), do: Enum.find(around, &is_binary/1)

  defp tagged(%{url: url, tags: tags} = source, url, folder) when is_binary(folder),
    do: %{source | tags: Enum.uniq(tags ++ [String.slice(folder, 0, 40)])}

  defp tagged(source, _url, _folder), do: source
end
