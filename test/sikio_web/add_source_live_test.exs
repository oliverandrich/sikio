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

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    %{conn: conn, user: user}
  end

  # One input takes a URL or a search term. Its hint names the supported platforms.
  test "one field takes a link or a search", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/add")
    assert has_element?(view, "#add-form input[name=q]")
    assert has_element?(view, "#add-hint", "PeerTube")
    # The hint states that non-URL input is searched in Apple Podcasts.
    assert has_element?(view, "#add-hint", "searched for in Apple Podcasts")
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
    assert Library.subscriptions(user) == []

    result = view |> element("#source-0 button", "Subscribe") |> render_click()
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
              %{collectionName: "Small Hours", artistName: "Ada", feedUrl: feed_url()},
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
    assert has_element?(view, "#results-heading", "Apple Podcasts")
    assert has_element?(view, "#source-0", "Ada")
    refute has_element?(view, "#source-0 button", "Preview")

    view |> element("#source-0 button", "Subscribe") |> render_click()
    assert_receive {:fetching, fetcher}
    assert has_element?(view, "#source-0 button[disabled]", "Subscribing")
    assert has_element?(view, "#source-1", "Other Show")
    send(fetcher, :answer)

    assert {"/feeds/" <> _, _flash} = assert_redirect(view)
    assert [%{feed: %{title: "Small Hours"}}] = Library.subscriptions(user)
  end

  # The clear button empties the input and removes the results.
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
    refute has_element?(view, "#results-heading")
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

    defp find(view, url) do
      view |> form("#add-form", %{q: url}) |> render_submit()
      render_async(view)
    end

    # A video link offers the video alone beside its channel. The queue is preselected, since a
    # single link is usually meant to be played.
    test "a video link adds only the video, to the queue by default", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")

      assert has_element?(view, "#single-item", "A good video")
      assert has_element?(view, ~s|#single-item input[name="at"][value="queue"][checked]|)
      assert has_element?(view, "#source-0", "Good Channel")

      result = view |> form("#single-item-form", %{at: "queue"}) |> render_submit()
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

      view |> form("#single-item-form", %{at: "inbox"}) |> render_change()
      assert has_element?(view, ~s|#single-item input[value="inbox"][checked]|)

      result = view |> form("#single-item-form", %{at: "inbox"}) |> render_submit()
      assert {:error, {:live_redirect, %{to: "/inbox/" <> _}}} = result
      assert Playback.queue(user) == []
      assert [_] = Library.entries(user, %{"status" => "inbox"})
    end

    # A removed item keeps its playback state. Saved again, it opens where that state lists it.
    test "an item saved again opens in the list that holds it", %{conn: conn, user: user} do
      stub_video()
      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")
      view |> form("#single-item-form", %{at: "queue"}) |> render_submit()
      [entry] = Library.entries(user)
      {:ok, _} = Playback.mark(user, entry.id, :heard)
      {:ok, _} = Library.remove_entry(user, entry.id)

      {:ok, view, _} = live(conn, ~p"/add")
      find(view, "https://youtu.be/abcdefghijk")
      view |> form("#single-item-form", %{at: "inbox"}) |> render_change()
      result = view |> form("#single-item-form", %{at: "inbox"}) |> render_submit()
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
