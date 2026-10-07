# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PicturesTest do
  use ExUnit.Case, async: true

  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Pictures

  @moduletag :tmp_dir

  import Sikio.PictureFixtures

  describe "candidates/1" do
    test "a video tries the widescreen sizes YouTube derives from its id, then its channel" do
      entry = %Entry{
        video_id: "dQw4w9WgXcQ",
        image_url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        feed: %Feed{kind: :youtube, icon_url: "https://yt3.example.org/channel.jpg"}
      }

      assert Pictures.candidates(entry) == [
               "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
               "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg",
               "https://yt3.example.org/channel.jpg"
             ]
    end

    test "an episode tries its own picture, then its source's artwork, and skips what is absent" do
      feed = %Feed{kind: :podcast, icon_url: "https://img.example.org/show.jpg"}

      assert Pictures.candidates(%Entry{image_url: "https://img.example.org/1.jpg", feed: feed}) ==
               ["https://img.example.org/1.jpg", "https://img.example.org/show.jpg"]

      assert Pictures.candidates(%Entry{image_url: nil, feed: %{feed | icon_url: nil}}) == []
    end
  end

  describe "fetch/2" do
    test "a picture is fetched once and then served from the cache", %{tmp_dir: dir} do
      serving(%{"/1.jpg" => {"image/jpeg", jpeg()}})

      assert {:ok, %{type: "image/jpeg", path: path}} =
               Pictures.fetch(["https://img.example.org/1.jpg"], dir)

      assert File.read!(path) == jpeg()
      assert_received {:fetched, "/1.jpg"}

      assert {:ok, %{type: "image/jpeg", path: ^path}} =
               Pictures.fetch(["https://img.example.org/1.jpg"], dir)

      refute_received {:fetched, _}
    end

    test "the next candidate is tried when one is missing", %{tmp_dir: dir} do
      serving(%{"/show.png" => {"image/png", png()}})

      urls = ["https://img.example.org/gone.jpg", "https://img.example.org/show.png"]
      assert {:ok, %{type: "image/png"}} = Pictures.fetch(urls, dir)
    end

    # An SVG can contain script, and the cache serves it from this origin.
    test "an SVG is refused even though it is an image", %{tmp_dir: dir} do
      serving(%{"/logo.svg" => {"image/svg+xml", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"}})

      assert Pictures.fetch(["https://img.example.org/logo.svg"], dir) == :error
    end

    # The `content-type` header and the file signature must agree.
    test "a body that is not the picture its header claims is refused", %{tmp_dir: dir} do
      serving(%{
        "/fake.png" => {"image/png", "<html>not a picture</html>"},
        "/page.jpg" => {"text/html", jpeg()}
      })

      assert Pictures.fetch(["https://img.example.org/fake.png"], dir) == :error
      assert Pictures.fetch(["https://img.example.org/page.jpg"], dir) == :error
    end

    test "a picture larger than the limit is refused", %{tmp_dir: dir} do
      serving(%{"/huge.jpg" => {"image/jpeg", jpeg() <> :binary.copy("x", 2_000_000)}})

      assert Pictures.fetch(["https://img.example.org/huge.jpg"], dir) == :error
    end

    # A failed URL is not requested again immediately. Otherwise every page listing the item
    # would request it.
    test "a failed picture is not fetched again straight away", %{tmp_dir: dir} do
      serving(%{})

      assert Pictures.fetch(["https://img.example.org/gone.jpg"], dir) == :error
      assert_received {:fetched, "/gone.jpg"}

      assert Pictures.fetch(["https://img.example.org/gone.jpg"], dir) == :error
      refute_received {:fetched, _}
    end
  end

  describe "fetch/2 when something goes wrong" do
    # Media types are case-insensitive.
    test "a type written in capitals is still a picture", %{tmp_dir: dir} do
      serving(%{"/caps.jpg" => {"Image/JPEG", jpeg()}})

      assert {:ok, %{type: "image/jpeg"}} =
               Pictures.fetch(["https://img.example.org/caps.jpg"], dir)
    end

    # A crash may leave an empty cache file. It is fetched again instead of being served.
    test "a damaged cache entry is fetched again", %{tmp_dir: dir} do
      serving(%{"/1.jpg" => {"image/jpeg", jpeg()}})
      {:ok, %{path: path}} = Pictures.fetch(["https://img.example.org/1.jpg"], dir)
      File.write!(path, "")

      assert {:ok, %{type: "image/jpeg"}} = Pictures.fetch(["https://img.example.org/1.jpg"], dir)
      assert File.read!(path) == jpeg()
    end

    # A cache write failure, such as a full disk, returns `:error` instead of raising.
    test "a cache that cannot be written is no picture rather than a crash", %{tmp_dir: dir} do
      serving(%{"/1.jpg" => {"image/jpeg", jpeg()}})
      blocked = Path.join(dir, "not-a-directory")
      File.write!(blocked, "")

      assert Pictures.fetch(["https://img.example.org/1.jpg"], blocked) == :error
    end
  end

  describe "prune/2" do
    # Pruning bounds the cache size. Serving a picture refreshes its mtime, which the age checks.
    test "pictures not served for longer than the age are removed", %{tmp_dir: dir} do
      serving(%{"/kept.jpg" => {"image/jpeg", jpeg()}, "/old.jpg" => {"image/jpeg", jpeg()}})
      long_ago = System.os_time(:second) - 31 * 86_400

      {:ok, %{path: kept}} = Pictures.fetch(["https://img.example.org/kept.jpg"], dir)
      {:ok, %{path: old}} = Pictures.fetch(["https://img.example.org/old.jpg"], dir)
      File.touch!(kept, long_ago)
      File.touch!(old, long_ago)

      {:ok, _} = Pictures.fetch(["https://img.example.org/kept.jpg"], dir)
      Pictures.prune(dir, 30 * 86_400)

      assert File.exists?(kept)
      refute File.exists?(old)
    end

    # The configured cache directory may contain other files.
    test "only the cache's own files are removed", %{tmp_dir: dir} do
      foreign = Path.join(dir, "notes.txt")
      File.write!(foreign, "keep me")
      File.touch!(foreign, System.os_time(:second) - 365 * 86_400)

      Pictures.prune(dir, 30 * 86_400)

      assert File.exists?(foreign)
    end

    test "a missing cache directory is nothing to prune", %{tmp_dir: dir} do
      assert Pictures.prune(Path.join(dir, "never-created"), 30 * 86_400) == :ok
    end
  end
end
