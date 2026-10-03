# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Chapters do
  @moduledoc """
  The chapters a publisher wrote into an item's description, and the description without them.

  Feeds rarely carry chapters as data, but many publishers list them in the notes, a line each:
  a time and a title. They are read from the stored description each time it is shown, like the
  notes themselves, so a better reading tomorrow applies to what was imported yesterday.

  Only a list that reads unmistakably as chapters is taken: at least three, each later than the
  one before, none beyond the item's length when that is known. Anything less may be a sentence
  that happens to begin with a time, and the notes then stay as they are.
  """

  @minimum 3

  # A time at the start of a line, perhaps in brackets, perhaps followed by a dash or a colon.
  @line ~r/^\s*[\(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?\s*[-–—:|•]?\s+(\S.*?)\s*$/u
  # A second time inside a line, set off by a dash, where a publisher lost a line break.
  @inline ~r/\s+((?:\d{1,2}:)?\d{1,2}:\d{2})\s+[-–—|]\s+/u
  # Where a line ends in markup or in text. Kept, so what is not a chapter is put back as it was.
  # In Unicode mode, or \R finds a next-line byte inside a character such as ✅.
  @breaks ~r{(<br\s*/?>|</(?:p|li|ul|ol|div|blockquote|h[1-6])>|\R)}iu

  @doc """
  The chapters in `description` and the description without their lines, or no chapters and the
  description untouched. `format` is `:html` or `:text`, `duration` the length in seconds or nil.
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

  # A title holding another time set off by a dash is two chapters.
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

  # A chapter line leaves only its markup behind, and the break after it goes with it. A
  # paragraph or a list item that held nothing else is dropped, and so is a list left empty.
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
end
