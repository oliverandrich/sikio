# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLiveTest do
  @moduledoc """
  Tests for the add page. Input is a feed URL or a search term.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo
  alias SikioWeb.Pictures

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    %{conn: conn, user: user}
  end

  # Answers the subscribe dialog. `choice` replaces its defaults.
  defp confirm_subscribe(view, choice \\ %{}) do
    if choice != %{}, do: view |> form("#subscribe-form", choice) |> render_change()
    view |> element("#confirm-subscribe") |> render_click()
  end

  # One input takes a URL or a search term. Its hint names the supported platforms.
  test "one field takes a link or a search", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/add")
    assert has_element?(view, "#add-form input[name=q]")
    assert has_element?(view, "#add-hint", "PeerTube")

    # The hint states that other input searches Apple Podcasts, the Mediathek, PeerTube and YouTube.
    assert has_element?(
             view,
             "#add-hint",
             "search Apple Podcasts, the Mediathek, PeerTube and YouTube"
           )

    assert has_element?(view, ~s|#add-q[aria-describedby="add-hint"]|)
    refute has_element?(view, "#discover-form")
    refute has_element?(view, "#search-form")
    refute has_element?(view, "#subscriptions")
    refute html =~ "Curated by you"
    assert has_element?(view, ~s|#add-button[aria-current="page"]|)
    assert has_element?(view, ~s|#tab-library[aria-current="page"]|)
  end

  # A new member has no other path to OPML import, so the add page links it.
  # The link follows the input because it is used less often.
  test "offers the OPML import after the field", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/add")
    assert has_element?(view, ~s|#add-opml[href="/subscriptions/import"]|)
    {form, _} = :binary.match(html, ~s|id="add-form"|)
    {opml, _} = :binary.match(html, ~s|id="add-opml"|)
    assert form < opml
  end

  # A pasted URL shows a preview without subscribing. Subscribe redirects to the feed page.
  test "pasted URLs preview a source, and subscribing leads to its page", %{
    conn: conn,
    user: user
  } do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: feed_url()}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#found-0", "Small Hours")
    # The feed's artwork, through Sikio's picture proxy.
    src = Pictures.path(["https://img.example.org/show.jpg"], ~p"/images/kind-audio.svg")
    assert has_element?(view, ~s|#found-0 img[src="#{src}"]|)
    assert Library.subscriptions(user) == []

    view |> element("#found-0 button", "Subscribe") |> render_click()
    result = confirm_subscribe(view)
    assert {:error, {:live_redirect, %{to: to}}} = result

    assert [%{feed_id: feed_id, feed: %{title: "Small Hours"}}] = Library.subscriptions(user)
    assert to == "/feeds/#{feed_id}-small-hours"

    {:ok, _source, html} = follow_redirect(result, conn)
    assert html =~ "Subscribed to Small Hours."
  end

  # Subscribing again keeps the custom name in the redirect slug and the flash.
  test "subscribing again leads to the source under its own name", %{conn: conn, user: user} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    url = feed_url()

    subscribe = fn ->
      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: url}) |> render_submit()
      render_async(view)
      view |> element("#found-0 button", "Subscribe") |> render_click()
      confirm_subscribe(view)
    end

    subscribe.()
    [subscription] = Library.subscriptions(user)
    {:ok, _} = Library.configure(user, subscription.id, %{"name" => "Late Night"}, [])

    result = subscribe.()
    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/feeds/#{subscription.feed_id}-late-night"

    {:ok, _source, html} = follow_redirect(result, conn)
    assert html =~ "Subscribed to Late Night."
  end

  # The sidebar names a followed source `source-<feed id>`. Search results need ids of their own,
  # or LiveView finds two elements under one id and patches the wrong one.
  test "search results and the sidebar never share an element id", %{conn: conn, user: user} do
    feed =
      Repo.insert!(%Sikio.Feeds.Feed{id: 1, url: feed_url(), title: "Followed", kind: :podcast})

    Repo.insert!(%Sikio.Library.Subscription{user_id: user.id, feed_id: feed.id})

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          Req.Test.json(conn, %{
            results: [
              %{collectionName: "Small Hours", artistName: "Ada", feedUrl: feed_url()},
              %{collectionName: "Other Show", artistName: "Bo", feedUrl: feed_url()}
            ]
          })

        _other ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "small hours"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#results", "Other Show")
    assert has_element?(view, "#sidebar a", "Followed")

    ids = view |> render() |> Floki.parse_document!() |> Floki.attribute("[id]", "id")
    assert ids -- Enum.uniq(ids) == []
  end

  # A search result subscribes without a preview step. Other results stay while the feed loads.
  test "a search result subscribes in one click", %{conn: conn, user: user} do
    test = self()

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          Req.Test.json(conn, %{
            results: [
              %{
                collectionName: "Small Hours",
                artistName: "Ada",
                feedUrl: feed_url(),
                artworkUrl100: "https://img.example/small-hours.jpg"
              },
              %{collectionName: "Other Show", artistName: "Bo", feedUrl: feed_url()}
            ]
          })

        # The stub blocks until the test has checked the disabled row.
        "/rss" ->
          send(test, {:fetching, self()})

          receive do
            :answer -> Plug.Conn.send_resp(conn, 200, podcast())
          end
      end
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "small hours"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#filter-podcasts", "2")
    assert has_element?(view, "#found-0", "Apple Podcasts")
    assert has_element?(view, "#found-0", "Ada")
    src = Pictures.path(["https://img.example/small-hours.jpg"], ~p"/images/kind-audio.svg")
    assert has_element?(view, ~s|#found-0 img[src="#{src}"]|)
    # A result without a cover shows the placeholder.
    assert has_element?(
             view,
             ~s|#found-1 img[src="#{Pictures.path([], ~p"/images/kind-audio.svg")}"]|
           )

    refute has_element?(view, "#found-0 button", "Preview")

    view |> element("#found-0 button", "Subscribe") |> render_click()
    confirm_subscribe(view)
    assert_receive {:fetching, fetcher}
    assert has_element?(view, "#found-0 button[disabled]", "Subscribing")
    assert has_element?(view, "#found-1", "Other Show")
    send(fetcher, :answer)

    assert {"/feeds/" <> _, _flash} = assert_redirect(view)
    assert [%{feed: %{title: "Small Hours"}}] = Library.subscriptions(user)
  end

  # Subscribing asks which present items to take and where later ones go. Nothing is subscribed
  # until the answer.
  test "subscribing asks which items to take and where they go", %{conn: conn, user: user} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast_later()) end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: feed_url()}) |> render_submit()
    render_async(view)

    view |> element("#found-0 button", "Subscribe") |> render_click()
    assert has_element?(view, "#subscribe-confirm", "Small Hours")
    assert has_element?(view, ~s|#subscribe-form [name="existing"][value="newest"][checked]|)
    assert has_element?(view, ~s|#subscribe-form [name="delivery"][value="inbox"][checked]|)

    view |> element("#cancel-subscribe") |> render_click()
    refute has_element?(view, "#subscribe-confirm")
    assert Library.subscriptions(user) == []

    view |> element("#found-0 button", "Subscribe") |> render_click()
    result = confirm_subscribe(view, %{existing: "all", delivery: "queue"})
    assert {:error, {:live_redirect, %{to: "/feeds/" <> _}}} = result
    assert [%{delivery: :queue}] = Library.subscriptions(user)
    assert length(Playback.queue(user)) == 2
  end

  # The archive takes every present item, so the first question goes away.
  test "choosing the archive asks nothing about present items", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: feed_url()}) |> render_submit()
    render_async(view)

    view |> element("#found-0 button", "Subscribe") |> render_click()
    view |> form("#subscribe-form", %{delivery: "skip"}) |> render_change()
    refute has_element?(view, ~s|#subscribe-form [name="existing"]|)
  end

  # The clear button empties the input and removes the results.
  describe "the Mediathek" do
    # An API result whose id and addresses no other test writes.
    defp programme(title) do
      n = Sikio.DataCase.unique()

      %{
        id: "id-#{n}",
        channel: "WDR",
        topic: "Tatort #{n}",
        title: title,
        description: "Fernsehfilm",
        timestamp: 1_791_656_100,
        duration: 5322,
        url_website: "https://mediathek#{n}.example.org/video/abc",
        url_video_hd: "https://wdr#{n}.example.org/v-hd.mp4"
      }
    end

    # Apple answers podcasts and episodes on one path, told apart by `entity`.
    defp searches(podcasts, episodes, programmes, extra \\ fn _conn -> nil end) do
      Req.Test.stub(HTTP, fn conn ->
        case {conn.request_path, URI.decode_query(conn.query_string)["entity"]} do
          {"/search", "podcast"} -> Req.Test.json(conn, %{results: podcasts})
          {"/search", "podcastEpisode"} -> Req.Test.json(conn, %{results: episodes})
          {"/api/query", _} -> Req.Test.json(conn, %{result: %{results: programmes}})
          _ -> extra.(conn)
        end
      end)
    end

    defp episode(title, feed) do
      %{
        trackName: title,
        collectionName: "Small Hours",
        feedUrl: feed,
        episodeGuid: "episode-1",
        releaseDate: "2026-09-18T09:00:00Z",
        trackTimeMillis: 3_723_000,
        description: String.duplicate("A long description of the episode. ", 8)
      }
    end

    # One list holds podcasts, their episodes, the Mediathek's series and its programmes. A pill
    # per kind shows its count and filters the list. A programme's actions show without a click.
    test "a search lists every kind at once, a pill filters it, and a programme goes to the queue",
         %{conn: conn, user: user} do
      searches(
        [%{collectionName: "Small Hours", feedUrl: feed_url()}],
        [episode("One & two", feed_url())],
        [programme("Die Erfindung des Rades"), programme("Spur")]
      )

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#filter-podcasts", "1")
      assert has_element?(view, "#filter-episodes", "1")
      assert has_element?(view, "#filter-series", "2")
      assert has_element?(view, "#filter-programmes", "2")
      assert has_element?(view, "#results #found-0")
      assert has_element?(view, "#results #programme-0")

      view |> element("#filter-programmes") |> render_click()
      assert has_element?(view, ~s|#filter-programmes[aria-pressed="true"]|)
      refute has_element?(view, "#search-hint")
      refute has_element?(view, "#found-0")
      assert has_element?(view, "#programme-0", "Die Erfindung des Rades")
      assert has_element?(view, "#programme-0", "WDR")
      assert has_element?(view, "#programme-0", "Fernsehfilm")
      assert has_element?(view, ~s|#programme-0 a[href^="https://mediathek"][target="_blank"]|)

      # A second press on the same pill shows every kind again.
      view |> element("#filter-programmes") |> render_click()
      assert has_element?(view, ~s|#filter-programmes[aria-pressed="false"]|)
      assert has_element?(view, "#found-0")

      result = view |> element(~s|#programme-0 [data-action="queue"]|) |> render_click()
      assert {:error, {:live_redirect, %{to: "/queue/" <> _}}} = result
      assert [id] = Playback.queue(user)
      assert %{feed: %{kind: :mediathek}} = Library.entry(user, id)
    end

    # MediathekViewWeb names no picture. A row's picture comes from its broadcaster's page,
    # through the picture proxy, once the row comes into view.
    test "programmes and series show their broadcaster's picture", %{conn: conn} do
      found = programme("Spur")
      searches([], [], [found])

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      for row <- ["#programme-0", "#series-0"] do
        [src] =
          view
          |> element(row <> ~s| img[loading="lazy"]|)
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("src")

        "/pictures/" <> reference = src

        assert Pictures.verify(reference) ==
                 {:ok, {[{:page, found.url_website}], "/images/kind-video.svg"}}
      end
    end

    # Programmes of one topic on one channel form a series, which is subscribed as a whole.
    test "the series tab groups programmes and subscribes to one", %{conn: conn, user: user} do
      maus = fn title ->
        Map.merge(programme(title), %{channel: "ARD", topic: "Die Sendung mit der Maus"})
      end

      # The search answers newest first. The older hit has its own date.
      older = %{maus.("Lachgeschichte") | timestamp: 1_791_000_000}

      searches([], [], [maus.("Sachgeschichte"), older], fn conn ->
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "maus"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#filter-series", "1")
      assert has_element?(view, "#series-0", "Die Sendung mit der Maus · ARD")
      # A series names the hit it was found by. A count of hits would read as its size.
      assert has_element?(
               view,
               ~s|#series-0 [title="Sachgeschichte"] .truncate|,
               "found: Sachgeschichte"
             )

      assert has_element?(view, "#series-0", "10 Oct 2026")
      refute has_element?(view, "#series-0", ~r/\d+ programmes?/)

      view |> element(~s|#series-0 [data-action="subscribe"]|) |> render_click()
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :mediathek}}] = Library.subscriptions(user)
    end

    # A series taken whole asks once for a larger page than its refreshes do.
    test "a series taken whole brings more programmes", %{conn: conn, user: user} do
      searches([], [], [programme("Spur")], fn conn ->
        assert URI.decode_query(conn.query_string)["size"] == "100"
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      view |> element(~s|#series-0 [data-action="subscribe"]|) |> render_click()
      confirm_subscribe(view, %{existing: "all", delivery: "inbox"})
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{url: url}}] = Library.subscriptions(user)
      assert URI.decode_query(URI.parse(url).query)["size"] == "20"
    end

    # The archive takes every programme, so a larger page would be wasted.
    test "a series sent to the archive asks for its usual page", %{conn: conn} do
      searches([], [], [programme("Spur")], fn conn ->
        assert URI.decode_query(conn.query_string)["size"] == "20"
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      view |> element(~s|#series-0 [data-action="subscribe"]|) |> render_click()
      view |> form("#subscribe-form", %{existing: "all"}) |> render_change()
      confirm_subscribe(view, %{delivery: "skip"})
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
    end

    # A programme row subscribes to the series it belongs to.
    test "a programme's series is subscribed from its row", %{conn: conn, user: user} do
      searches([], [], [programme("Spur")], fn conn ->
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      assert has_element?(view, ~s|#programme-0 [data-action="subscribe"]|, "Subscribe to Tatort")
      view |> element(~s|#programme-0 [data-action="subscribe"]|) |> render_click()
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :mediathek}}] = Library.subscriptions(user)
    end

    # An episode behaves as a programme does. Saving it reads its podcast's feed first.
    test "an episode goes to the inbox, and its description shows in full on request", %{
      conn: conn,
      user: user
    } do
      url = feed_url()

      searches([], [episode("One & two", url)], [], fn conn ->
        Plug.Conn.send_resp(conn, 200, podcast())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "small hours"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#episode-0", "One & two")
      assert has_element?(view, "#episode-0", "Small Hours")
      assert has_element?(view, "#episode-0 [data-description].line-clamp-2")

      view |> element("#episode-0 [data-more]") |> render_click()
      refute has_element?(view, "#episode-0 [data-description].line-clamp-2")

      view |> element(~s|#episode-0 [data-action="inbox"]|) |> render_click()
      assert {"/inbox/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :podcast}}] = Library.entries(user, %{"status" => "inbox"})
      assert Library.subscriptions(user) == []
    end

    # An episode row subscribes to its podcast through the podcast's feed.
    test "an episode's podcast is subscribed from its row", %{conn: conn, user: user} do
      searches([], [episode("One & two", feed_url())], [], fn conn ->
        Plug.Conn.send_resp(conn, 200, podcast())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "small hours"}) |> render_submit()
      render_async(view)

      view |> element(~s|#episode-0 [data-action="subscribe"]|) |> render_click()
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :podcast}}] = Library.subscriptions(user)
    end

    # A retry cannot help when the feed no longer holds the episode, so the row says so.
    test "an episode missing from its feed says so on its row", %{conn: conn} do
      gone = %{episode("One & two", feed_url()) | episodeGuid: "episode-gone"}

      searches([], [gone], [], fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "small hours"}) |> render_submit()
      render_async(view)

      view |> element(~s|#episode-0 [data-action="queue"]|) |> render_click()
      render_async(view)
      assert has_element?(view, "#episode-0 [role=alert]", "no longer in its podcast's feed")
    end

    # Each search reports on its own. Apple's results stay when the Mediathek fails.
    test "an unreachable Mediathek leaves the podcasts", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/search" ->
            Req.Test.json(conn, %{
              results: [%{collectionName: "Small Hours", feedUrl: feed_url()}]
            })

          "/api/query" ->
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#found-0", "Small Hours")
      assert has_element?(view, "#programmes-error", "Mediathek")
      refute has_element?(view, "#discovery-error")
    end

    # A pasted link is no search, so the Mediathek is not asked.
    test "a pasted link asks no Mediathek", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn ->
        refute conn.request_path == "/api/query"
        Plug.Conn.send_resp(conn, 200, podcast())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: feed_url()}) |> render_submit()
      render_async(view)
      refute has_element?(view, "#search-filters")
    end
  end

  describe "PeerTube" do
    # A channel from the index, named uniquely so no concurrent test subscribes to the same feed.
    defp channel_hit do
      n = Sikio.DataCase.unique()

      %{
        url: "https://tube#{n}.example.org/video-channels/linux",
        displayName: "Linux #{n}",
        host: "tube#{n}.example.org",
        videosCount: 12,
        avatars: [%{width: 120, fileUrl: "https://tube#{n}.example.org/avatars/120.png"}]
      }
    end

    # The index answers channels and videos. Apple and the Mediathek find nothing.
    defp peertube_searches(channels, videos, extra \\ fn _conn -> nil end) do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/api/v1/search/video-channels" -> Req.Test.json(conn, %{data: channels})
          "/api/v1/search/videos" -> Req.Test.json(conn, %{data: videos})
          "/search" -> Req.Test.json(conn, %{results: []})
          "/api/query" -> Req.Test.json(conn, %{result: %{results: []}})
          "/results" -> Plug.Conn.send_resp(conn, 200, youtube_results([]))
          _ -> extra.(conn)
        end
      end)
    end

    # A channel row shows its instance and subscribes through the channel's address.
    test "a channel from the index is subscribed from its row", %{conn: conn, user: user} do
      hit = channel_hit()

      peertube_searches([hit], [], fn conn ->
        assert conn.request_path == "/video-channels/linux"
        Plug.Conn.send_resp(conn, 200, peertube())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "linux"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#filter-channels", "PeerTube channels")
      assert has_element?(view, "#filter-channels", "1")
      assert has_element?(view, "#channel-0", hit.displayName)
      assert has_element?(view, "#channel-0", hit.host)

      [src] =
        view
        |> element("#channel-0 img")
        |> render()
        |> then(&Regex.run(~r|src="/pictures/([^"]+)"|, &1, capture: :all_but_first))

      assert {:ok, {[avatar], _fallback}} = Pictures.verify(src)
      assert avatar == "https://#{hit.host}/avatars/120.png"

      view |> element("#channel-0 [data-action=subscribe]") |> render_click()
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :peertube}}] = Library.subscriptions(user)
    end

    # Each search reports on its own. The podcasts stay when the index fails.
    test "an unreachable index leaves the podcasts", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/search" ->
            Req.Test.json(conn, %{
              results: [%{collectionName: "Small Hours", feedUrl: feed_url()}]
            })

          _ ->
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "linux"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#found-0", "Small Hours")
      assert has_element?(view, "#channels-error", "PeerTube")
      refute has_element?(view, "#discovery-error")
    end

    test "a forged channel key subscribes to nothing", %{conn: conn, user: user} do
      peertube_searches([channel_hit()], [])

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "linux"}) |> render_submit()
      render_async(view)

      render_click(view, "subscribe", %{"list" => "channels", "key" => "99"})
      refute has_element?(view, "#subscribe-form")
      assert Library.subscriptions(user) == []
    end

    # A video from the index on its own instance, named uniquely like `channel_hit/0`.
    defp video_hit do
      n = Sikio.DataCase.unique()

      %{
        url: "https://tube#{n}.example.org/videos/watch/f00d-#{n}",
        name: "A talk #{n}",
        duration: 754,
        publishedAt: "2026-09-05T08:00:48.437Z",
        thumbnailUrl: "https://tube#{n}.example.org/thumbnails/#{n}.jpg",
        channel: %{url: "https://tube#{n}.example.org/video-channels/linux", displayName: "Linux"}
      }
    end

    # The video's instance: the video API and the channel feed. The index names PeerTube videos
    # only, so NodeInfo is not asked. `video` answers the video API.
    defp instance(hit, video) do
      %URI{path: "/videos/watch/" <> id} = URI.parse(hit.url)

      fn conn ->
        case conn.request_path do
          "/.well-known/nodeinfo" ->
            flunk("asked NodeInfo")

          "/api/v1/videos/" <> ^id ->
            video.(conn)

          _feed_or_channel ->
            Plug.Conn.send_resp(conn, 200, peertube())
        end
      end
    end

    defp found(hit),
      do: &Req.Test.json(&1, %{name: hit.name, shortUUID: "sh0rt", channel: %{id: 7}})

    # A video row shows its channel and goes to the queue without a subscription.
    test "a video from the index goes to the queue", %{conn: conn, user: user} do
      hit = video_hit()
      peertube_searches([], [hit], instance(hit, found(hit)))

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "linux"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#filter-videos", "PeerTube videos")
      assert has_element?(view, "#filter-videos", "1")
      assert has_element?(view, "#video-0", hit.name)
      assert has_element?(view, "#video-0", "Linux")

      view |> element(~s|#video-0 [data-action="queue"]|) |> render_click()
      assert {"/queue/" <> _, _flash} = assert_redirect(view)
      assert [id] = Playback.queue(user)
      assert %{feed: %{kind: :peertube}} = Library.entry(user, id)
      assert Library.subscriptions(user) == []
    end

    test "a video's channel is subscribed from its row", %{conn: conn, user: user} do
      hit = video_hit()
      peertube_searches([], [hit], instance(hit, found(hit)))

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "linux"}) |> render_submit()
      render_async(view)

      assert has_element?(view, ~s|#video-0 [data-action="subscribe"]|, "Subscribe to Linux")
      view |> element(~s|#video-0 [data-action="subscribe"]|) |> render_click()
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :peertube}}] = Library.subscriptions(user)
    end

    # The index can hold a video its instance has deleted since, or an instance that is down.
    test "a video its instance does not serve says so on its row", %{conn: conn, user: user} do
      hit = video_hit()
      peertube_searches([], [hit], instance(hit, &Plug.Conn.send_resp(&1, 404, "")))

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "linux"}) |> render_submit()
      render_async(view)

      view |> element(~s|#video-0 [data-action="inbox"]|) |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#video-0 [role=alert]",
               "could not be read from its PeerTube instance"
             )

      assert Library.entries(user) == []
    end

    # A pasted link is no search, so the index is not asked.
    test "a pasted link asks no index", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn ->
        refute String.starts_with?(conn.request_path, "/api/v1/search")
        Plug.Conn.send_resp(conn, 200, podcast())
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: feed_url()}) |> render_submit()
      render_async(view)
      refute has_element?(view, "#search-filters")
    end
  end

  test "the search is cleared with its results", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{
        results: [%{collectionName: "Small Hours", artistName: "Ada", feedUrl: feed_url()}]
      })
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    refute has_element?(view, "#clear-search")

    view |> form("#add-form", %{q: "small hours"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#found-0")

    view |> element("#clear-search") |> render_click()
    refute has_element?(view, "#found-0")
    refute has_element?(view, "#search-filters")
    assert has_element?(view, ~s|#add-q[value=""]|)
    refute has_element?(view, "#clear-search")
  end

  # A new search cancels a pending subscribe. The late feed response subscribes nothing.
  test "a new search abandons a subscription still loading", %{conn: conn, user: user} do
    test = self()

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          Req.Test.json(conn, %{
            results: [%{collectionName: "Small Hours", artistName: "Ada", feedUrl: feed_url()}]
          })

        "/rss" ->
          send(test, {:fetching, self()})

          receive do
            :answer -> Plug.Conn.send_resp(conn, 200, podcast())
          end
      end
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "small hours"}) |> render_submit()
    render_async(view)
    view |> element("#found-0 button", "Subscribe") |> render_click()
    confirm_subscribe(view)
    assert_receive {:fetching, fetcher}

    view |> form("#add-form", %{q: "other"}) |> render_submit()
    send(fetcher, :answer)
    render_async(view)

    assert Library.subscriptions(user) == []
    assert has_element?(view, "#found-0 button:not([disabled])", "Subscribe")
  end

  # A failed feed fetch shows an alert in its row. Other rows keep an enabled Subscribe button.
  test "a search result whose feed fails says so on its row", %{conn: conn, user: user} do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          Req.Test.json(conn, %{
            results: [
              %{collectionName: "Gone Show", artistName: "Ada", feedUrl: feed_url()},
              %{collectionName: "Other Show", artistName: "Bo", feedUrl: feed_url()}
            ]
          })

        _ ->
          Plug.Conn.send_resp(conn, 503, "down")
      end
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "gone"}) |> render_submit()
    render_async(view)
    view |> element("#found-0 button", "Subscribe") |> render_click()
    confirm_subscribe(view)
    render_async(view)

    assert has_element?(view, "#found-0 [role=alert]")
    assert has_element?(view, "#found-1 button:not([disabled])", "Subscribe")
    assert Library.subscriptions(user) == []
  end

  test "discovery failures are visible and forged result IDs do not subscribe", %{
    conn: conn,
    user: user
  } do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: feed_url()}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#discovery-error")
    render_hook(view, "select", %{id: "999"})
    # An answer without an open dialog subscribes nothing.
    render_hook(view, "confirm_subscribe", %{})
    assert Library.subscriptions(user) == []
  end

  # LiveView restores form input on reconnect only for forms with `phx-change`.
  # Without it the template's empty value replaces the input.
  test "what was typed stays in the field after a change event", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "https://example.org/rs"}) |> render_change()
    assert render(view) =~ "https://example.org/rs"
  end

  # Input with a dot is treated as a URL. On failure the page offers a search for that input.
  test "a link that finds nothing offers to search for it instead", %{conn: conn} do
    test = self()

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          send(test, {:search_term, Plug.Conn.fetch_query_params(conn).query_params["term"]})
          Req.Test.json(conn, %{results: []})

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "mr.robot"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#discovery-error")

    # The search uses the failed input, not the edited field value.
    view |> form("#add-form", %{q: "something else"}) |> render_change()
    view |> element("#search-instead") |> render_click()
    render_async(view)
    assert has_element?(view, "#no-results")
    assert_received {:search_term, "mr.robot"}
  end

  # Input with an explicit scheme is a URL, so its failure offers no search.
  test "a written-out address that fails offers no search", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "https://example.org/nothing"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#discovery-error")
    refute has_element?(view, "#search-instead")
  end

  describe "YouTube search" do
    # YouTube's results page answers channels and videos. Every other search finds nothing.
    defp youtube_searches(channels, videos, extra) do
      Req.Test.stub(HTTP, fn conn ->
        case {conn.request_path, URI.decode_query(conn.query_string)} do
          {"/results", %{"sp" => "EgIQAg=="}} ->
            Plug.Conn.send_resp(conn, 200, youtube_results(channels))

          {"/results", _videos} ->
            Plug.Conn.send_resp(conn, 200, youtube_results(videos))

          {"/search", _} ->
            Req.Test.json(conn, %{results: []})

          {"/api/query", _} ->
            Req.Test.json(conn, %{result: %{results: []}})

          {"/api/v1/search/" <> _, _} ->
            Req.Test.json(conn, %{data: []})

          _ ->
            extra.(conn)
        end
      end)
    end

    # The channel's feed and page. The channel id is unique, so no concurrent test shares it.
    defp youtube_channel(conn) do
      case conn.request_path do
        "/feeds/videos.xml" -> Plug.Conn.send_resp(conn, 200, youtube())
        "/channel/" <> _ -> Plug.Conn.send_resp(conn, 200, channel_page())
      end
    end

    defp unique_channel_id,
      do: URI.decode_query(URI.parse(youtube_feed_url()).query)["channel_id"]

    test "a channel from YouTube is subscribed from its row", %{conn: conn, user: user} do
      hit = youtube_channel_hit("good", %{channelId: unique_channel_id()})
      youtube_searches([hit], [], &youtube_channel/1)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "good"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#filter-youtube_channels", "YouTube channels")

      assert has_element?(view, "#youtube-channel-0", "Channel good")
      assert has_element?(view, "#youtube-channel-0", "youtube.com")

      assert {:ok, {["https://yt3.ggpht.com/good=s176"], _fallback}} =
               picture(view, "#youtube-channel-0 img")

      view |> element("#youtube-channel-0 [data-action=subscribe]") |> render_click()
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :youtube}}] = Library.subscriptions(user)
    end

    # The video is saved as its pasted link would be, without a subscription.
    test "a video from YouTube goes to the queue", %{conn: conn, user: user} do
      channel = unique_channel_id()

      owner = %{
        runs: [
          %{text: "Good Channel", navigationEndpoint: %{browseEndpoint: %{browseId: channel}}}
        ]
      }

      youtube_searches([], [youtube_video_hit("abcdefghijk", %{ownerText: owner})], fn conn ->
        case conn.request_path do
          "/oembed" ->
            Req.Test.json(conn, %{
              title: "A good video",
              author_url: "https://www.youtube.com/channel/" <> channel
            })

          _ ->
            youtube_channel(conn)
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "good"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#filter-youtube_videos", "YouTube videos")
      assert has_element?(view, "#youtube-video-0", "Video abcdefghijk")
      assert has_element?(view, "#youtube-video-0", "Good Channel")

      view |> element(~s|#youtube-video-0 [data-action="queue"]|) |> render_click()
      assert {"/queue/" <> _, _flash} = assert_redirect(view)
      assert [id] = Playback.queue(user)
      assert %{feed: %{kind: :youtube}} = Library.entry(user, id)
      assert Library.subscriptions(user) == []
    end

    # A consent page or a bot check carries no results. Pasting a link still works.
    test "an unreadable results page points to pasting a link", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/search" ->
            Req.Test.json(conn, %{
              results: [%{collectionName: "Small Hours", feedUrl: feed_url()}]
            })

          "/results" ->
            Plug.Conn.send_resp(conn, 200, "<html><body>Before you continue</body></html>")

          _ ->
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "good"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#found-0", "Small Hours")
      assert has_element?(view, "#youtube-channels-error", "paste the channel's link")
      assert has_element?(view, "#youtube-videos-error", "paste the video's link")
      refute has_element?(view, "#discovery-error")
    end
  end

  describe "one ranked list" do
    # Apple answers `podcasts` and YouTube answers `channels`. The other searches find nothing.
    defp ranked_searches(podcasts, channels, youtube \\ nil) do
      test = self()

      Req.Test.stub(HTTP, fn conn ->
        case {conn.request_path, URI.decode_query(conn.query_string)} do
          {"/results", %{"sp" => "EgIQAg=="}} when is_function(youtube) ->
            youtube.(conn)

          {"/results", %{"sp" => "EgIQAg=="}} ->
            Plug.Conn.send_resp(conn, 200, youtube_results(channels))

          {path, query} ->
            # Each search's task reports itself, so a test can wait for all but one.
            send(test, {:answered, self()})
            nothing_but(conn, path, query, podcasts)
        end
      end)
    end

    defp nothing_but(conn, "/search", %{"entity" => "podcast"}, podcasts),
      do: Req.Test.json(conn, %{results: podcasts})

    defp nothing_but(conn, "/search", _query, _podcasts), do: Req.Test.json(conn, %{results: []})

    defp nothing_but(conn, "/api/query", _query, _podcasts),
      do: Req.Test.json(conn, %{result: %{results: []}})

    defp nothing_but(conn, "/api/v1/search/" <> _, _query, _podcasts),
      do: Req.Test.json(conn, %{data: []})

    defp nothing_but(conn, "/results", _query, _podcasts),
      do: Plug.Conn.send_resp(conn, 200, youtube_results([]))

    defp show(title), do: %{collectionName: title, artistName: "Ada", feedUrl: feed_url()}

    defp rows(view) do
      view
      |> element("#results")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("article", "id")
    end

    # Each index ranks by its own measure. The list orders all hits by their title's match.
    test "hits from every search are ordered by how well they match", %{conn: conn} do
      ranked_searches([show("Other Show"), show("Good")], [youtube_channel_hit("good")])

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "good"}) |> render_submit()
      render_async(view)

      assert rows(view) == ["found-1", "youtube-channel-0", "found-0"]
      assert has_element?(view, "#youtube-channel-0", "YouTube")
    end

    test "the list shows the best 20, and a pill shows every hit of its kind", %{conn: conn} do
      ranked_searches(Enum.map(1..25, &show("Show #{&1}")), [])

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "show"}) |> render_submit()
      render_async(view)

      assert length(rows(view)) == 20
      assert has_element?(view, "#filter-podcasts", "25")
      # A kind without hits shows no pill.
      refute has_element?(view, "#filter-episodes")

      view |> element("#filter-podcasts") |> render_click()
      assert length(rows(view)) == 25
    end

    # Rows that jumped as each search answered would move under the pointer. The list waits for
    # the slowest search, and a deadline ends the wait. A later answer joins the list.
    test "the list waits for every search until its deadline", %{conn: conn} do
      test = self()

      ranked_searches([show("Good")], [], fn conn ->
        send(test, {:blocked, self()})

        receive do
          :answer ->
            Plug.Conn.send_resp(conn, 200, youtube_results([youtube_channel_hit("good")]))
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "good"}) |> render_submit()
      assert_receive {:blocked, youtube}

      # Six searches answer. Their tasks end once the view holds their results.
      for _search <- 1..6 do
        assert_receive {:answered, task}
        ref = Process.monitor(task)
        assert_receive {:DOWN, ^ref, :process, _, _}
      end

      assert has_element?(view, "#filter-podcasts", "1")
      assert has_element?(view, "#search-loading")
      assert rows(view) == []

      # The list shows what came in. The loading line stays for the search still running.
      send(view.pid, {:settle, "good"})
      assert has_element?(view, "#search-loading")
      assert rows(view) == ["found-0"]

      send(youtube, :answer)
      render_async(view)
      refute has_element?(view, "#search-loading")
      assert rows(view) == ["found-0", "youtube-channel-0"]
    end

    # An empty list at the deadline is no answer yet while a search still runs.
    test "nothing is reported found while a search still runs", %{conn: conn} do
      test = self()

      ranked_searches([], [], fn conn ->
        send(test, {:blocked, self()})
        receive do: (:answer -> Plug.Conn.send_resp(conn, 200, youtube_results([])))
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "good"}) |> render_submit()
      assert_receive {:blocked, youtube}

      send(view.pid, {:settle, "good"})
      refute has_element?(view, "#no-results")

      send(youtube, :answer)
      render_async(view)
      assert has_element?(view, "#no-results")
    end
  end

  describe "a platform that is off" do
    setup do
      admin = Repo.insert!(%User{username: unique_username(), admin: true})
      {:ok, _} = Sikio.Platforms.set(admin, :youtube, false)
      :ok
    end

    # No request goes to YouTube, and its kinds have no pills.
    test "is not searched", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn ->
        refute conn.request_path == "/results", "asked YouTube"

        case conn.request_path do
          "/search" ->
            Req.Test.json(conn, %{results: [%{collectionName: "Good", feedUrl: feed_url()}]})

          "/api/query" ->
            Req.Test.json(conn, %{result: %{results: []}})

          _ ->
            Req.Test.json(conn, %{data: []})
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      assert has_element?(view, "#add-hint", "Apple Podcasts")
      refute has_element?(view, "#add-hint", "YouTube")

      view |> form("#add-form", %{q: "good"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#found-0", "Good")
      refute has_element?(view, "#filter-youtube_channels")
      refute has_element?(view, "#search-loading")
    end

    # Without the podcast search, the page still says a term is too short.
    test "a term that is too short is answered without the podcast search", %{conn: conn} do
      admin = Repo.insert!(%User{username: unique_username(), admin: true})
      {:ok, _} = Sikio.Platforms.set(admin, :podcast, false)
      Req.Test.stub(HTTP, fn _conn -> flunk("searched with a term that is too short") end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "a"}) |> render_submit()

      assert has_element?(view, "#search-error", "between 2 and 120 characters")
    end

    test "refuses its links", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, youtube()) end)

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: youtube_feed_url()}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#discovery-error", "switched off on this instance")
      refute has_element?(view, "#found-0")
    end
  end

  describe "a single item" do
    # The channel id comes from a unique feed URL, so no concurrent test saves the same feed.
    defp stub_video do
      channel = URI.decode_query(URI.parse(youtube_feed_url()).query)["channel_id"]

      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/oembed" ->
            Req.Test.json(conn, %{
              title: "A good video",
              author_url: "https://www.youtube.com/channel/" <> channel
            })

          "/feeds/videos.xml" ->
            Plug.Conn.send_resp(conn, 200, youtube())

          "/channel/" <> _ ->
            Plug.Conn.send_resp(conn, 200, channel_page())
        end
      end)
    end

    defp picture(view, selector) do
      [src] =
        view
        |> element(selector)
        |> render()
        |> then(&Regex.run(~r|src="/pictures/([^"]+)"|, &1, capture: :all_but_first))

      Pictures.verify(src)
    end

    defp find(view, url) do
      view |> form("#add-form", %{q: url}) |> render_submit()
      render_async(view)
    end

    # A video link shows the video as a search shows a hit: one row that adds it to the queue or
    # the inbox, or subscribes to its channel. The channel needs no row of its own.
    test "a video link adds only the video, to the queue", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")

      assert has_element?(view, "#single-item", "A good video")
      assert has_element?(view, "#single-item", "Good Channel")
      # The video's own thumbnail comes first, the channel's picture after it.
      assert {:ok,
              {["https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg" | _],
               "/images/kind-video.svg"}} =
               picture(view, "#single-item img")

      assert has_element?(
               view,
               ~s|#single-item [data-action="subscribe"]|,
               "Subscribe to Good Channel"
             )

      refute has_element?(view, "#found-0")

      result = view |> element(~s|#single-item [data-action="queue"]|) |> render_click()
      assert {:error, {:live_redirect, %{to: to}}} = result
      [entry] = Library.entries(user)
      assert to == "/queue/#{entry.id}-a-good-video"
      assert Playback.queue(user) == [entry.id]
      assert Library.subscriptions(user) == []
    end

    test "the inbox can be chosen instead", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")

      result = view |> element(~s|#single-item [data-action="inbox"]|) |> render_click()
      assert {:error, {:live_redirect, %{to: "/inbox/" <> _}}} = result
      assert Playback.queue(user) == []
      assert [_] = Library.entries(user, %{"status" => "inbox"})
    end

    # A removed item keeps its playback state. Saved again, it opens where that state lists it.
    test "an item saved again opens in the list that holds it", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")
      view |> element(~s|#single-item [data-action="queue"]|) |> render_click()
      [entry] = Library.entries(user)
      {:ok, _} = Playback.mark(user, entry.id, :heard)
      {:ok, _} = Library.remove_entry(user, entry.id)

      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")
      result = view |> element(~s|#single-item [data-action="inbox"]|) |> render_click()
      assert {:error, {:live_redirect, %{to: "/history/" <> _}}} = result
      {:ok, _view, html} = follow_redirect(result, conn)
      assert html =~ "Saved A good video."
    end

    # A bookmarklet or a share sheet opens the page with the link already in it.
    test "a link in the address starts the lookup", %{conn: conn} do
      stub_video()
      url = "https://youtu.be/abcdefghijk"
      {:ok, view, _} = live(conn, "/add?" <> URI.encode_query(%{url: url}))
      render_async(view)

      assert has_element?(view, ~s|#add-q[value="#{url}"]|)
      assert has_element?(view, "#single-item", "A good video")
    end

    # The row subscribes to the item's source after the dialog, as a search row does.
    test "a video link subscribes to its channel from the row", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")

      view |> element(~s|#single-item [data-action="subscribe"]|) |> render_click()
      assert has_element?(view, "#subscribe-confirm", "Good Channel")
      confirm_subscribe(view)
      assert {"/feeds/" <> _, _flash} = assert_redirect(view)
      assert [%{feed: %{kind: :youtube}}] = Library.subscriptions(user)
    end

    # A click from a row the page already cleared names no item. It subscribes nothing.
    test "a subscribe for an item that is gone does nothing", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/add")
      render_hook(view, "subscribe", %{"list" => "item", "key" => "item"})
      refute has_element?(view, "#subscribe-confirm")
      assert Library.subscriptions(user) == []
    end

    # An episode's page leads to its podcast's feed. Its notes show as plain text in the row.
    test "a podcast episode link shows the episode as a row", %{conn: conn} do
      feed = feed_url()

      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/episodes/1" ->
            Plug.Conn.send_resp(
              conn,
              200,
              ~s(<link rel="alternate" type="application/rss+xml" href="#{feed}">)
            )

          _ ->
            Plug.Conn.send_resp(conn, 200, podcast())
        end
      end)

      {:ok, view, _} = live(conn, ~p"/add")
      find(view, podcast_page())

      assert has_element?(view, "#single-item", "One & two")
      assert has_element?(view, "#single-item", "Small Hours")
      assert has_element?(view, "#single-item [data-description]", "Notes with a link.")
      refute render(element(view, "#single-item")) =~ "&lt;p&gt;"

      assert has_element?(
               view,
               ~s|#single-item [data-action="subscribe"]|,
               "Subscribe to Small Hours"
             )

      refute has_element?(view, "#found-0")
      refute has_element?(view, "#no-results")
    end

    test "a feed link offers no single item", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, feed_url())

      assert has_element?(view, "#found-0", "Small Hours")
      refute has_element?(view, "#single-item")
    end
  end
end
