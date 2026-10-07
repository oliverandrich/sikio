# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Chapters do
  @moduledoc """
  Parses chapters from an item's description and returns the description without them.

  Few feeds carry chapters as data, but many publishers list them in the notes: one timestamp and
  title per line. They are parsed from the stored description on each render, like the notes.
  Parser improvements therefore apply to existing entries.

  Only an unambiguous list counts: at least three chapters, strictly increasing, none beyond the
  known duration. Otherwise a sentence that starts with a time could match. The notes then stay
  unchanged.
  """

  @minimum 3

  # A timestamp at line start, optionally bracketed, optionally followed by a separator character.
  @line ~r/^\s*[\(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?\s*[-–—:|•]?\s+(\S.*?)\s*$/u
  # A second timestamp inside a line, set off by a dash or pipe, from a missing line break.
  @inline ~r/\s+((?:\d{1,2}:)?\d{1,2}:\d{2})\s+[-–—|]\s+/u
  # Line ends in HTML or plain text. Captured, so non-chapter text is restored unchanged.
  # The `u` flag is required, or \R matches a next-line byte inside a character such as ✅.
  @breaks ~r{(<br\s*/?>|</(?:p|li|ul|ol|div|blockquote|h[1-6])>|\R)}iu

  @doc """
  Returns an entry's chapters and the notes to show beside them, with one rule for every caller.

  Chapters from the feed are explicit, so two suffice and the notes stay whole. Otherwise
  chapters are parsed from the notes, and their lines are removed. `length` is the entry's known
  duration in seconds, possibly measured by a player.
  """
  def of(%{chapters: [_, _ | _] = chapters, description: description}, _length) do
    {Enum.map(chapters, &%{at: &1["at"], title: &1["title"]}), description}
  end

  def of(entry, length), do: split(entry.description, entry.description_format || :html, length)

  @doc """
  Returns the chapters in `description` and the description without their lines. Without
  chapters, returns `[]` and the unchanged description. `format` is `:html` or `:text`.
  `duration` is the length in seconds or nil.
  """
  def split(nil, _format, _duration), do: {[], nil}

  def split(description, format, duration) do
    pieces = Regex.split(@breaks, description, include_captures: true)
    read = Enum.map(pieces, &chapters_in(&1, format))
    chapters = read |> Enum.reject(&is_nil/1) |> List.flatten()

    if clear?(chapters, duration),
      do: {chapters, without(pieces, read)},
      else: {[], description}
  end

  defp chapters_in(piece, format) do
    case Regex.run(@line, text(piece, format)) do
      [_, at, title] -> inline([{seconds(at), title}])
      nil -> nil
    end
  end

  # A title containing further dash-separated timestamps yields several chapters.
  defp inline([{at, title}]) do
    case Regex.split(@inline, title, include_captures: true, trim: true) do
      [title] ->
        [%{at: at, title: title}]

      [title | rest] ->
        later =
          rest
          |> Enum.chunk_every(2)
          |> Enum.map(fn [stamp, title] ->
            [_, at] = Regex.run(~r/((?:\d{1,2}:)?\d{1,2}:\d{2})/, stamp)
            %{at: seconds(at), title: String.trim(title)}
          end)

        [%{at: at, title: String.trim(title)} | later]
    end
  end

  defp text(piece, :text), do: piece

  defp text(piece, _html) do
    case Floki.parse_fragment(piece) do
      {:ok, tree} -> Floki.text(tree)
      _ -> ""
    end
  end

  defp seconds(stamp) do
    stamp |> String.split(":") |> Enum.reduce(0, &(&2 * 60 + String.to_integer(&1)))
  end

  defp clear?(chapters, duration) do
    times = Enum.map(chapters, & &1.at)

    length(chapters) >= @minimum and times == Enum.sort(Enum.uniq(times)) and
      (is_nil(duration) or List.last(times) <= duration)
  end

  # A chapter line keeps only its tags, and the following line break is removed. Paragraphs or
  # list items left empty are dropped, and so are empty lists.
  defp without(pieces, read) do
    pieces
    |> Enum.zip(read)
    |> drop_breaks()
    |> Enum.join()
    |> String.replace(~r{<(p|li)>\s*</\1>}i, "")
    |> String.replace(~r{<(ul|ol)>\s*</\1>}i, "")
  end

  defp drop_breaks([{piece, chapters}, {break, nil} | rest]) when not is_nil(chapters) do
    tags = Regex.scan(~r/<[^>]+>/, piece) |> List.flatten() |> Enum.join()

    if Regex.match?(~r{^(<br\s*/?>|\R)$}iu, break),
      do: [tags | drop_breaks(rest)],
      else: [tags | drop_breaks([{break, nil} | rest])]
  end

  defp drop_breaks([{piece, chapters} | rest]) when not is_nil(chapters) do
    [Regex.scan(~r/<[^>]+>/, piece) |> List.flatten() |> Enum.join() | drop_breaks(rest)]
  end

  defp drop_breaks([{piece, nil} | rest]), do: [piece | drop_breaks(rest)]
  defp drop_breaks([]), do: []

  @doc """
  Parses a Podcasting 2.0 chapters file into the stored shape: a start in seconds and a title.
  Chapters marked `"toc": false` are hidden markers and skipped. An invalid file returns `[]`.
  """
  def from_json(body) do
    case Jason.decode(body) do
      {:ok, %{"chapters" => chapters}} when is_list(chapters) ->
        chapters
        |> Enum.filter(&listed?/1)
        |> Enum.map(&%{"at" => trunc(&1["startTime"]), "title" => String.trim(&1["title"])})
        |> Enum.sort_by(& &1["at"])
        |> Enum.take(500)

      _ ->
        []
    end
  end

  defp listed?(%{"startTime" => at, "title" => title} = chapter)
       when is_number(at) and at >= 0 and is_binary(title),
       do: chapter["toc"] != false and String.trim(title) != ""

  defp listed?(_chapter), do: false
end
