# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.OPML.Handler do
  @moduledoc """
  Reads outlines out of an OPML document, with every limit enforced while parsing.

  The file comes from somebody else's application, so the bounds are checked as the document is
  consumed rather than afterwards: node count, nesting depth, address length and the number of
  distinct sources. A folder names a tag for the sources inside it, the innermost one counting,
  and a source listed in two folders is one source with both tags.
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
    # Every open element carries the folder name it opens, or nil, so ending it lets go of it.
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

  # Normalising before comparing is what makes the deduplication work: the same feed is often
  # listed twice with a different host case or scheme.
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

  # The innermost folder around the outline being read, which the outline itself is not.
  defp folder(%{folders: [_own | around]}), do: Enum.find(around, &is_binary/1)

  defp tagged(%{url: url, tags: tags} = source, url, folder) when is_binary(folder),
    do: %{source | tags: Enum.uniq(tags ++ [String.slice(folder, 0, 40)])}

  defp tagged(source, _url, _folder), do: source
end
