# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures do
  @moduledoc """
  Pictures from a publisher's server, fetched by Sikio and kept on its own disk.

  A browser that loaded them directly would tell every publisher who is reading, and the content
  security policy refuses them anyway. Each fetch goes through `Sikio.Feeds.HTTP`, so a picture
  address is checked like a feed address.

  Only raster formats are kept. An SVG may carry script, and it would be served from this origin.

  Every file this module touches is the operator's directory joined with a SHA-256 hash, never a
  name a caller chose. That is why the file functions below skip Sobelow's traversal check.
  """
  alias Sikio.Feeds.HTTP

  @max_bytes 2_000_000

  # A failed address is asked again after a day. Every page that lists the item would otherwise
  # ask on every render.
  @retry_after 86_400

  # A cached picture, a remembered failure, or a write that did not finish. Nothing else in the
  # directory is the cache's to remove.
  @own_file ~r/\A[A-Za-z0-9_-]{43}(\.failed|\.\d+\.partial)?\z/

  @doc """
  The addresses to try for an entry, best first.

  YouTube derives every size from the video id. The feed names the letterboxed 4 by 3 one, so the
  widescreen sizes are asked for instead, the largest first because not every video has it.
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
  The first candidate that yields a picture, from the cache or fetched into it.

  Answers `{:ok, %{type: type, path: path}}`, or `:error` when no candidate does. A cache file
  that is missing, unreadable or not a picture is fetched again.
  """
  def fetch(urls, dir \\ cache_dir()) do
    Enum.find_value(urls, :error, &picture(&1, dir))
  end

  @doc """
  Removes every cache file that was not served for `max_age` seconds.

  Serving a picture renews its modification time, so this is the age since anybody asked.
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

  @doc "Where pictures are kept. Configured by the operator, outside the release."
  def cache_dir, do: Application.fetch_env!(:sikio, :picture_cache_dir)

  defp picture(url, dir) do
    path = Path.join(dir, :crypto.hash(:sha256, url) |> Base.url_encode64(padding: false))

    case served(path) do
      {:ok, picture} -> {:ok, picture}
      :error -> unless failed_recently?(path), do: download(url, path)
    end
  end

  # Only the first bytes are read: they say the type, and the file is sent as it is.
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

  # A cache that cannot be written costs the picture, not the page, so a failed write is a miss.
  defp download(url, path) do
    with {:ok, %{status: 200} = response} <- HTTP.get(url, max_bytes: @max_bytes),
         true <- claims_raster?(response.headers),
         type when is_binary(type) <- type(response.body),
         :ok <- write(path, response.body) do
      {:ok, %{type: type, path: path}}
    else
      _ ->
        write(path <> ".failed", "")
        nil
    end
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

  # The type is read from the bytes, not from the publisher's header.
  defp type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp type(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  defp type(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: "image/gif"
  defp type(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  defp type(_bytes), do: nil

  # Written beside its final name and renamed, so a reader never sees half a file.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(path, body) do
    partial = path <> ".#{System.unique_integer([:positive])}.partial"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(partial, body),
         do: File.rename(partial, path)
  end
end
