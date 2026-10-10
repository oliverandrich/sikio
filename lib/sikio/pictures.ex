# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures do
  @moduledoc """
  Fetches publisher pictures on the server and caches them on local disk.

  Direct loading would expose each reader's IP address to the publisher. The content security
  policy blocks it as well. Each fetch goes through `Sikio.Feeds.HTTP`, so picture URLs get the
  same checks as feed URLs.

  Only raster formats are cached. An SVG can contain script and would be served from this origin.

  Every file path is the configured directory joined with a SHA-256 hash, never a caller's name.
  The file functions below therefore skip Sobelow's traversal check.
  """
  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.HTTP

  @max_bytes 2_000_000

  # A failed candidate is retried after one day: a picture that failed, or a page that names none.
  # Otherwise every page listing the item would refetch it on each render.
  @retry_after 86_400

  # Matches a cached picture, a failure marker or an unfinished write. Pruning removes nothing
  # else from the directory.
  @own_file ~r/\A[A-Za-z0-9_-]{43}(\.failed|\.\d+\.partial)?\z/

  @doc """
  Returns the URLs to try for an entry, best first. The feed icon is the last fallback.

  YouTube serves every thumbnail size under the video id. The feed links the letterboxed 4:3
  size, so the widescreen sizes are used instead. `maxresdefault` comes first, but not every
  video has it.
  """
  def candidates(entry) do
    own =
      if entry.video_id do
        for size <- ~w(maxresdefault mqdefault),
            do: "https://i.ytimg.com/vi/#{entry.video_id}/#{size}.jpg"
      else
        [entry.image_url]
      end

    Enum.reject(own ++ [entry.feed.icon_url], &is_nil/1)
  end

  @doc """
  Returns the first candidate that yields a picture, from the cache or freshly fetched.

  A candidate is a picture's URL, or `{:page, url}` for the preview picture a web page names.
  Returns `{:ok, %{type: type, path: path}}`, or `:error` when no candidate does. A missing,
  unreadable or invalid cache file is fetched again, unless the candidate failed within the last
  day.
  """
  def fetch(candidates, dir \\ cache_dir()) do
    Enum.find_value(candidates, :error, &picture(&1, dir))
  end

  @doc """
  Deletes every cache file not served for `max_age` seconds.

  Serving a picture updates its modification time, so the age counts from the last request.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def prune(dir \\ cache_dir(), max_age) do
    cutoff = System.os_time(:second) - max_age

    with {:ok, names} <- File.ls(dir) do
      for name <- names,
          Regex.match?(@own_file, name),
          path = Path.join(dir, name),
          match?({:ok, %{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix)),
          do: File.rm(path)
    end

    :ok
  end

  @doc "Returns the picture cache directory. The operator configures it outside the release."
  def cache_dir, do: Application.fetch_env!(:sikio, :picture_cache_dir)

  # `{:page, url}` names a web page whose preview picture is fetched, as for a search result. The
  # picture is cached under the page, so a cached one needs no request to the page.
  defp picture(candidate, dir) do
    path = cache_path(cache_key(candidate), dir)

    case served(path) do
      {:ok, picture} -> {:ok, picture}
      :error -> unless failed_recently?(path), do: fetch_into(candidate, path)
    end
  end

  defp cache_key({:page, page}), do: "page " <> page
  defp cache_key(url), do: url

  # A page that did not answer is asked again on the next request.
  defp fetch_into({:page, page}, path) do
    case Discovery.page_picture(page) do
      {:ok, url} -> download(url, path)
      {:error, :unavailable} -> nil
      {:error, :not_found} -> missed(path)
    end
  end

  defp fetch_into(url, path), do: download(url, path)

  defp cache_path(key, dir),
    do: Path.join(dir, :crypto.hash(:sha256, key) |> Base.url_encode64(padding: false))

  # Reads only the first 12 bytes to detect the type. The file is sent unchanged.
  # sobelow_skip ["Traversal.FileModule"]
  defp served(path) do
    with {:ok, head} when is_binary(head) <-
           File.open(path, [:read, :binary], &IO.binread(&1, 12)),
         type when is_binary(type) <- type(head) do
      File.touch(path)
      {:ok, %{type: type, path: path}}
    else
      _ -> :error
    end
  end

  defp failed_recently?(path) do
    case File.stat(path <> ".failed", time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime < @retry_after
      _ -> false
    end
  end

  # An unwritable cache loses the picture, not the page. A failed write counts as a miss.
  defp download(url, path) do
    with {:ok, %{status: 200} = response} <- HTTP.get(url, max_bytes: @max_bytes),
         true <- claims_raster?(response.headers),
         type when is_binary(type) <- type(response.body),
         :ok <- write(path, response.body) do
      {:ok, %{type: type, path: path}}
    else
      _ -> missed(path)
    end
  end

  defp missed(path) do
    write(path <> ".failed", "")
    nil
  end

  defp claims_raster?(headers) do
    case Map.get(headers, "content-type", []) do
      [type | _] ->
        type = String.downcase(type)
        String.starts_with?(type, "image/") and not String.contains?(type, "svg")

      [] ->
        false
    end
  end

  # The returned type comes from the magic bytes, not from the publisher's `content-type`.
  defp type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp type(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  defp type(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: "image/gif"
  defp type(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  defp type(_bytes), do: nil

  # Writes a temporary file and renames it, so a reader never sees a partial file.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(path, body) do
    partial = path <> ".#{System.unique_integer([:positive])}.partial"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(partial, body),
         do: File.rename(partial, path)
  end
end
