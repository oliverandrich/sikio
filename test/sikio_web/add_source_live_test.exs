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

  # The page names what its field takes, so nobody has to sort a link before pasting it.
  test "the field names the kinds of links it takes", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/add")
    assert has_element?(view, "#discover-hint", "PeerTube")
    assert has_element?(view, "#search-form")
    refute has_element?(view, "#subscriptions")
    assert has_element?(view, ~s|#add-button[aria-current="page"]|)
    assert has_element?(view, ~s|#tab-library[aria-current="page"]|)
  end

  # A collection from another app comes in from here too, since a new member has no other way in.
  test "offers the OPML import beside the search", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/add")
    assert has_element?(view, ~s|#add-opml[href="/subscriptions/import"]|)
  end

  # A source is previewed before anything is subscribed. Subscribing leads to the new source's
  # own page, where its episodes, tags and deliveries are.
  test "pasted URLs preview a source, and subscribing leads to its page", %{
    conn: conn,
    user: user
  } do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#discover-form", %{url: feed_url()}) |> render_submit()
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
      view |> form("#discover-form", %{url: url}) |> render_submit()
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

  test "Apple search results can be previewed and subscribed", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          Req.Test.json(conn, %{
            results: [
              %{
                collectionName: "Small Hours",
                artistName: "Ada",
                feedUrl: feed_url()
              }
            ]
          })

        "/rss" ->
          Plug.Conn.send_resp(conn, 200, podcast())
      end
    end)

    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#search-form", %{term: "small hours"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#source-0", "Ada")
    view |> element("#source-0 button", "Preview") |> render_click()
    render_async(view)
    assert has_element?(view, "#source-0 button", "Subscribe")
  end

  test "discovery failures are visible and forged result IDs do not subscribe", %{
    conn: conn,
    user: user
  } do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#discover-form", %{url: feed_url()}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#discovery-error")
    render_hook(view, "select", %{id: "999"})
    assert Library.subscriptions(user) == []
  end

  # Both forms carry a phx-change handler, which is what lets a reconnecting browser put back what
  # somebody had typed. Without it the text is silently replaced by the template's empty value.
  test "what was typed survives a reconnect", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/add")
    view |> form("#discover-form", %{url: "https://example.org/rs"}) |> render_change()
    view |> form("#search-form", %{term: "small ho"}) |> render_change()

    html = render(view)
    assert html =~ "https://example.org/rs"
    assert html =~ "small ho"
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

    view |> form("#discover-form", %{url: "https://video.example.org"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#source-0", "Good Instance Videos")

    assert {:error, {:redirect, %{to: "/feeds/" <> _}}} =
             view |> element("#source-0 button", "Subscribe") |> render_click()
  end
end
