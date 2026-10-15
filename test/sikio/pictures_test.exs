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

  describe "candidates/1, Mediathek" do
    # MediathekViewWeb names no picture. The broadcaster's page does, under the same cache key
    # as in a search, so a programme seen there and then saved costs one fetch.
    test "a programme without a picture tries its broadcaster's page" do
      feed = %Feed{kind: :mediathek, icon_url: nil}
      page = "https://www.ardmediathek.de/video/yang-1"

      assert Pictures.candidates(%Entry{page_url: page, image_url: nil, feed: feed}) ==
               [{:page, page}]

      # A picture stored earlier comes first.
      assert Pictures.candidates(%Entry{
               page_url: page,
               image_url: "https://img/1.jpg",
               feed: feed
             }) ==
               ["https://img/1.jpg"]

      # Other kinds keep their own picture alone.
      assert Pictures.candidates(%Entry{
               page_url: page,
               image_url: nil,
               feed: %Feed{kind: :podcast}
             }) ==
               []
    end
  end

  # The process that holds a page request.
  # A turn passes through the gate's process, so a loaded machine may take longer than the
  # default 100 ms.
  defp asked do
    assert_receive {:asked, pid}, 2_000
    pid
  end

  describe "source_icons/1" do
    # A TV series has no picture of its own. Its broadcaster's icon stands in.
    test "a TV series without an icon uses its broadcaster's" do
      url = "https://mediathekviewweb.de/feed?query=%21WDR+%23Tatort&size=20"
      series = %Feed{kind: :mediathek, url: url, icon_url: nil}

      assert Pictures.source_icons(series) == [{:site_icon, "https://www1.wdr.de"}]

      assert Pictures.source_icons(%{series | icon_url: "https://img/s.jpg"}) == [
               "https://img/s.jpg"
             ]

      assert Pictures.source_icons(%Feed{kind: :podcast, url: url, icon_url: nil}) == []

      # A programme without a picture of its own falls back to it.
      entry = %Entry{page_url: "https://www.ard.example/v/1", image_url: nil, feed: series}

      assert Pictures.candidates(entry) == [
               {:page, entry.page_url},
               {:site_icon, "https://www1.wdr.de"}
             ]
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

    # A search result names only its broadcaster's page. The page names the picture, and the
    # picture is cached under the page, so a later view asks the broadcaster nothing.
    test "a page's picture is found through the page and cached under it", %{tmp_dir: dir} do
      serving(%{
        "/video/1" => {"text/html", ~s(<meta property="og:image" content="/img/1.jpg">)},
        "/img/1.jpg" => {"image/jpeg", jpeg()},
        "/video/bare" => {"text/html", "<title>No picture</title>"}
      })

      page = {:page, "https://www.ard.example/video/1"}
      assert {:ok, %{type: "image/jpeg", path: path}} = Pictures.fetch([page], dir)
      assert File.read!(path) == jpeg()
      assert_received {:fetched, "/video/1"}
      assert_received {:fetched, "/img/1.jpg"}

      assert {:ok, %{path: ^path}} = Pictures.fetch([page], dir)
      refute_received {:fetched, _}

      # A page without a picture is not asked again within the retry time.
      bare = {:page, "https://www.ard.example/video/bare"}
      assert Pictures.fetch([bare], dir) == :error
      assert_received {:fetched, "/video/bare"}
      assert Pictures.fetch([bare], dir) == :error
      refute_received {:fetched, _}
    end

    # A programme seen in a search and then saved shares the cache file, in either order.
    test "a saved programme's picture is the one its search result fetched", %{tmp_dir: dir} do
      serving(%{
        "/video/1" => {"text/html", ~s(<meta property="og:image" content="/img/1.jpg">)},
        "/img/1.jpg" => {"image/jpeg", jpeg()}
      })

      page = "https://www.ard.example/video/1"
      entry = %Entry{page_url: page, image_url: nil, feed: %Feed{kind: :mediathek}}

      assert {:ok, %{path: path}} = Pictures.fetch([{:page, page}], dir)
      assert_received {:fetched, "/video/1"}
      assert_received {:fetched, "/img/1.jpg"}

      assert {:ok, %{path: ^path}} = Pictures.fetch(Pictures.candidates(entry), dir)
      refute_received {:fetched, _}

      # Saved first, searched later.
      other = %{entry | page_url: "https://www.ard.example/video/2"}

      serving(%{
        "/video/2" => {"text/html", ~s(<meta property="og:image" content="/img/1.jpg">)},
        "/img/1.jpg" => {"image/jpeg", jpeg()}
      })

      assert {:ok, %{path: saved}} = Pictures.fetch(Pictures.candidates(other), dir)
      assert_received {:fetched, "/video/2"}
      assert {:ok, %{path: ^saved}} = Pictures.fetch([{:page, other.page_url}], dir)
      refute_received {:fetched, "/video/2"}
    end

    # A list of new programmes asks their pages a few at a time, so no broadcaster sees a burst.
    test "at most four pages are fetched at once", %{tmp_dir: dir} do
      test = self()

      Req.Test.stub(Sikio.Feeds.HTTP, fn conn ->
        send(test, {:asked, self()})
        receive do: (:answer -> Plug.Conn.send_resp(conn, 200, "<title>No picture</title>"))
      end)

      tasks =
        for n <- 1..6,
            do: Task.async(fn -> Pictures.fetch([{:page, "https://ard.example/v/#{n}"}], dir) end)

      asked = for _ <- 1..4, do: asked()

      # The other two wait at the gate, and no page beyond four was asked.
      Stream.repeatedly(fn -> :sys.get_state(Sikio.Pictures.Pages).waiting end)
      |> Enum.find(&(:queue.len(&1) == 2))

      refute_received {:asked, _}

      Enum.each(asked, &send(&1, :answer))
      later = for _ <- 1..2, do: asked()
      Enum.each(later, &send(&1, :answer))
      assert Enum.map(tasks, &Task.await/1) == List.duplicate(:error, 6)
    end

    # A broadcaster's icon is fetched once and kept under its site.
    test "a site's icon is found through the site and cached under it", %{tmp_dir: dir} do
      serving(%{
        "/" => {"text/html", ~s(<link rel="apple-touch-icon" href="/touch.png">)},
        "/touch.png" => {"image/png", png()}
      })

      site = {:site_icon, "https://www1.wdr.example/"}
      assert {:ok, %{type: "image/png", path: path}} = Pictures.fetch([site], dir)
      assert_received {:fetched, "/"}
      assert_received {:fetched, "/touch.png"}

      assert {:ok, %{path: ^path}} = Pictures.fetch([site], dir)
      refute_received {:fetched, _}
    end

    # A hanging broadcaster page holds one of the four page turns. It gives up after the page
    # timeout, so the row shows its fallback and other pictures get their turn.
    test "a page that does not answer in time yields the fallback", %{tmp_dir: dir} do
      test = self()

      Req.Test.stub(Sikio.Feeds.HTTP, fn conn ->
        send(test, {:fetched, conn.request_path})

        case conn.request_path do
          "/video/hanging" ->
            receive do: (:never -> conn)

          "/fallback.jpg" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/jpeg", nil)
            |> Plug.Conn.send_resp(200, jpeg())
        end
      end)

      candidates = [
        {:page, "https://www.ard.example/video/hanging"},
        "https://img.example.org/fallback.jpg"
      ]

      {elapsed, result} =
        :timer.tc(fn -> Pictures.fetch(candidates, dir, page_timeout: 100) end, :millisecond)

      assert {:ok, %{type: "image/jpeg"}} = result
      assert elapsed < 2_000
      assert_received {:fetched, "/video/hanging"}
      assert_received {:fetched, "/fallback.jpg"}

      # The page is asked again in ten minutes, as a page that answered with an error.
      [marker] = Path.wildcard(Path.join(dir, "*.failed"))
      %{mtime: next} = File.stat!(marker, time: :posix)
      assert (next - System.os_time(:second)) in 595..600
    end

    # A busy broadcaster is asked again after ten minutes, not on every render. Only a final
    # answer waits a day.
    test "a page that did not answer is asked again later", %{tmp_dir: dir} do
      Req.Test.stub(Sikio.Feeds.HTTP, &Plug.Conn.send_resp(&1, 503, ""))
      page = {:page, "https://www.ard.example/video/busy"}
      assert Pictures.fetch([page], dir) == :error

      serving(%{})
      assert Pictures.fetch([page], dir) == :error
      refute_received {:fetched, _}

      # Ten minutes later, the marker's time has come.
      for marker <- Path.wildcard(Path.join(dir, "*.failed")) do
        %{mtime: next} = File.stat!(marker, time: :posix)
        assert (next - System.os_time(:second)) in 595..600
        File.touch!(marker, next - 601)
      end

      serving(%{
        "/video/busy" => {"text/html", ~s(<meta property="og:image" content="/1.jpg">)},
        "/1.jpg" => {"image/jpeg", jpeg()}
      })

      assert {:ok, %{type: "image/jpeg"}} = Pictures.fetch([page], dir)
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

    # Some servers send no content type. The magic bytes determine the picture's type.
    test "a picture without a stated type is taken by its bytes", %{tmp_dir: dir} do
      Req.Test.stub(Sikio.Feeds.HTTP, &Plug.Conn.send_resp(&1, 200, png()))
      assert {:ok, %{type: "image/png"}} = Pictures.fetch(["https://img.example.org/icon"], dir)
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
