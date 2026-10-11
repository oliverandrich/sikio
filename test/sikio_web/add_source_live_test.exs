# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLiveTest do
  @moduledoc """
  Tests for the add page. Input is a feed URL or an Apple Podcasts search term.
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
    # The hint states that other input searches Apple Podcasts and the Mediathek.
    assert has_element?(view, "#add-hint", "search Apple Podcasts and the Mediathek")
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
    assert has_element?(view, "#source-0", "Small Hours")
    # The feed's artwork, through Sikio's picture proxy.
    src = Pictures.path(["https://img.example.org/show.jpg"], ~p"/images/kind-audio.svg")
    assert has_element?(view, ~s|#source-0 img[src="#{src}"]|)
    assert Library.subscriptions(user) == []

    view |> element("#source-0 button", "Subscribe") |> render_click()
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
      view |> element("#source-0 button", "Subscribe") |> render_click()
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
    assert has_element?(view, ~s|#tab-podcasts[aria-selected="true"]|, "2")
    assert has_element?(view, "#panel-podcasts", "Apple Podcasts")
    assert has_element?(view, "#source-0", "Ada")
    src = Pictures.path(["https://img.example/small-hours.jpg"], ~p"/images/kind-audio.svg")
    assert has_element?(view, ~s|#source-0 img[src="#{src}"]|)
    # A result without a cover shows the placeholder.
    assert has_element?(
             view,
             ~s|#source-1 img[src="#{Pictures.path([], ~p"/images/kind-audio.svg")}"]|
           )

    refute has_element?(view, "#source-0 button", "Preview")

    view |> element("#source-0 button", "Subscribe") |> render_click()
    confirm_subscribe(view)
    assert_receive {:fetching, fetcher}
    assert has_element?(view, "#source-0 button[disabled]", "Subscribing")
    assert has_element?(view, "#source-1", "Other Show")
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

    view |> element("#source-0 button", "Subscribe") |> render_click()
    assert has_element?(view, "#subscribe-confirm", "Small Hours")
    assert has_element?(view, ~s|#subscribe-form [name="existing"][value="newest"][checked]|)
    assert has_element?(view, ~s|#subscribe-form [name="delivery"][value="inbox"][checked]|)

    view |> element("#cancel-subscribe") |> render_click()
    refute has_element?(view, "#subscribe-confirm")
    assert Library.subscriptions(user) == []

    view |> element("#source-0 button", "Subscribe") |> render_click()
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

    view |> element("#source-0 button", "Subscribe") |> render_click()
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

    # Four tabs: podcasts, their episodes, the Mediathek's series and its programmes. Each
    # shows its count. A programme's actions show without a click.
    test "a search fills four tabs, and a programme goes to the queue", %{conn: conn, user: user} do
      searches(
        [%{collectionName: "Small Hours", feedUrl: feed_url()}],
        [episode("One & two", feed_url())],
        [programme("Die Erfindung des Rades"), programme("Spur")]
      )

      {:ok, view, _} = live(conn, ~p"/add")
      view |> form("#add-form", %{q: "tatort"}) |> render_submit()
      render_async(view)

      assert has_element?(view, ~s|#tab-podcasts[aria-selected="true"]|, "1")
      assert has_element?(view, "#tab-episodes", "1")
      assert has_element?(view, "#tab-series", "2")
      assert has_element?(view, "#tab-programmes", "2")
      assert has_element?(view, "#panel-programmes.hidden")

      view |> element("#tab-programmes") |> render_click()
      assert has_element?(view, ~s|#tab-programmes[aria-selected="true"]|)
      assert has_element?(view, "#panel-podcasts.hidden")
      assert has_element?(view, "#programme-0", "Die Erfindung des Rades")
      assert has_element?(view, "#programme-0", "WDR")
      assert has_element?(view, "#programme-0", "Fernsehfilm")
      assert has_element?(view, ~s|#programme-0 a[href^="https://mediathek"][target="_blank"]|)

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

      # Without podcasts, the first tab with results opens.
      assert has_element?(view, ~s|#tab-series[aria-selected="true"]|, "1")
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

      assert has_element?(view, ~s|#tab-episodes[aria-selected="true"]|)
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

      assert has_element?(view, "#source-0", "Small Hours")
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
      refute has_element?(view, "#search-tabs")
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
    assert has_element?(view, "#source-0")

    view |> element("#clear-search") |> render_click()
    refute has_element?(view, "#source-0")
    refute has_element?(view, "#search-tabs")
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
    view |> element("#source-0 button", "Subscribe") |> render_click()
    confirm_subscribe(view)
    assert_receive {:fetching, fetcher}

    view |> form("#add-form", %{q: "other"}) |> render_submit()
    send(fetcher, :answer)
    render_async(view)

    assert Library.subscriptions(user) == []
    assert has_element?(view, "#source-0 button:not([disabled])", "Subscribe")
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
    view |> element("#source-0 button", "Subscribe") |> render_click()
    confirm_subscribe(view)
    render_async(view)

    assert has_element?(view, "#source-0 [role=alert]")
    assert has_element?(view, "#source-1 button:not([disabled])", "Subscribe")
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

    # A video link offers the video alone beside its channel, to the queue or the inbox.
    test "a video link adds only the video, to the queue", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")

      assert has_element?(view, "#single-item", "A good video")
      # The video's own thumbnail comes first, the channel's picture after it.
      assert {:ok,
              {["https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg" | _],
               "/images/kind-video.svg"}} =
               picture(view, "#single-item img")

      assert {:ok, {[_channel], "/images/kind-video.svg"}} = picture(view, "#source-0 img")
      assert has_element?(view, "#single-item img.aspect-video")
      assert has_element?(view, "#single-item #add-to-inbox")
      assert has_element?(view, "#source-0", "Good Channel")

      result = view |> element("#add-to-queue") |> render_click()
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

      result = view |> element("#add-to-inbox") |> render_click()
      assert {:error, {:live_redirect, %{to: "/inbox/" <> _}}} = result
      assert Playback.queue(user) == []
      assert [_] = Library.entries(user, %{"status" => "inbox"})
    end

    # A removed item keeps its playback state. Saved again, it opens where that state lists it.
    test "an item saved again opens in the list that holds it", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")
      view |> element("#add-to-queue") |> render_click()
      [entry] = Library.entries(user)
      {:ok, _} = Playback.mark(user, entry.id, :heard)
      {:ok, _} = Library.remove_entry(user, entry.id)

      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")
      result = view |> element("#add-to-inbox") |> render_click()
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

    test "a feed link offers no single item", %{conn: conn} do
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, feed_url())

      assert has_element?(view, "#source-0", "Small Hours")
      refute has_element?(view, "#single-item")
    end
  end
end
