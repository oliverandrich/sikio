# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLiveTest do
  @moduledoc """
  Adding a source: a link or a podcast search, previewed before anything is subscribed.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Library
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    %{conn: conn, user: user}
  end

  # One field takes a link or a search, and says which links it knows.
  test "one field takes a link or a search", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/add")
    assert has_element?(view, "#add-form input[name=q]")
    assert has_element?(view, "#add-hint", "PeerTube")
    # Words that are not a link go to Apple, and the page says so before anything is sent.
    assert has_element?(view, "#add-hint", "searched for in Apple Podcasts")
    assert has_element?(view, ~s|#add-q[aria-describedby="add-hint"]|)
    refute has_element?(view, "#discover-form")
    refute has_element?(view, "#search-form")
    refute has_element?(view, "#subscriptions")
    refute html =~ "Curated by you"
    assert has_element?(view, ~s|#add-button[aria-current="page"]|)
    assert has_element?(view, ~s|#tab-library[aria-current="page"]|)
  end

  # A collection from another app comes in from here too, since a new member has no other way in.
  # It is the rarer way, so it comes after the field.
  test "offers the OPML import after the field", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/add")
    assert has_element?(view, ~s|#add-opml[href="/subscriptions/import"]|)
    {form, _} = :binary.match(html, ~s|id="add-form"|)
    {opml, _} = :binary.match(html, ~s|id="add-opml"|)
    assert form < opml
  end

  # A source is previewed before anything is subscribed. Subscribing leads to the new source's
  # own page, where its episodes, tags and deliveries are.
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

  # A source subscribed to before keeps the name the member gave it, in the address and the flash.
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
    {:ok, _} = Library.update_subscription(user, subscription.id, %{"name" => "Late Night"})

    result = subscribe.()
    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/feeds/#{subscription.feed_id}-late-night"

    {:ok, _source, html} = follow_redirect(result, conn)
    assert html =~ "Subscribed to Late Night."
  end

  # A search result subscribes in one click. The other results stay while its feed loads.
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

        # The feed responds after the test sees the disabled row.
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

  # The field clears with its results, for the next search.
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

  # A new search abandons a subscription still loading, so the page stays with the new results.
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

  # A feed that cannot be read shows its error on its own row. The other results stay usable.
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

  # The form carries a phx-change handler, which is what lets a reconnecting browser put back what
  # somebody had typed. Without it the text is silently replaced by the template's empty value.
  test "what was typed survives a reconnect", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "https://example.org/rs"}) |> render_change()
    assert render(view) =~ "https://example.org/rs"
  end

  # A word with a dot reads as an address. When it leads nowhere, the same words can be searched.
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

    # Edited in the meantime, the field does not change what failed as a link.
    view |> form("#add-form", %{q: "something else"}) |> render_change()
    view |> element("#search-instead") |> render_click()
    render_async(view)
    assert has_element?(view, "#no-results")
    assert_received {:search_term, "mr.robot"}
  end

  # An address written out with its scheme was meant as one, so its failure offers no search.
  test "a written-out address that fails offers no search", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#add-form", %{q: "https://example.org/nothing"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#discovery-error")
    refute has_element?(view, "#search-instead")
  end

  # The policy is written on a document, and moving inside a LiveView writes no document. A
  # PeerTube instance subscribed to without one would not be in the policy the page loaded with,
  # so its first video would be refused by the browser. Subscribing to a new instance therefore
  # asks for a page.
  test "subscribing to a new instance reloads the page that has to frame it", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        path when path in [nil, "/"] ->
          Plug.Conn.send_resp(conn, 200, "<html><head></head><body></body></html>")

        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://video.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "peertube"}})

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, peertube())
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/add")

    view |> form("#add-form", %{q: "https://video.example.org"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#source-0", "Good Instance Videos")

    assert {:error, {:redirect, %{to: "/feeds/" <> _}}} =
             view |> element("#source-0 button", "Subscribe") |> render_click()
  end
end
