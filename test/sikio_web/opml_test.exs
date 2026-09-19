defmodule SikioWeb.OPMLTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.OPML
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user), user: user}
  end

  test "OPML export is an authenticated download scoped to the current account", c do
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    Library.subscribe(c.user, preview)
    conn = get(c.conn, "/subscriptions.opml")
    assert response(conn, 200) =~ "xmlUrl"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="sikio-subscriptions.opml")
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert {:ok, [%{url: "https://example.org/rss"}]} = OPML.parse(conn.resp_body)
    assert build_conn() |> get("/subscriptions.opml") |> redirected_to() == "/login"
  end

  test "file upload previews sources before importing and reports partial failure", c do
    Req.Test.stub(HTTP, fn conn ->
      if conn.request_path == "/rss",
        do: Plug.Conn.send_resp(conn, 200, podcast()),
        else: Plug.Conn.send_resp(conn, 503, "down")
    end)

    {:ok, view, _} = live(c.conn, "/subscriptions/import")

    xml =
      ~s(<opml version="2.0"><body><outline text="Podcast" xmlUrl="https://example.org/rss"/><outline text="Broken" xmlUrl="https://example.org/broken"/></body></opml>)

    upload =
      file_input(view, "#opml-upload-form", :opml, [
        %{name: "subscriptions.opml", content: xml, type: "text/xml"}
      ])

    render_upload(upload, "subscriptions.opml")
    view |> form("#opml-upload-form") |> render_submit()
    assert has_element?(view, "#opml-sources", "Podcast")
    assert Library.subscriptions(c.user) == []
    view |> element("#import-opml") |> render_click()
    render_async(view)
    assert has_element?(view, "#opml-summary", "1 imported")
    assert has_element?(view, "#opml-summary", "1 failed")
    assert has_element?(view, "#opml-sources", "Could not read this feed")
    assert [%{feed: %{title: "Small Hours"}}] = Library.subscriptions(c.user)
  end

  test "invalid uploads never offer an import action", c do
    {:ok, view, _} = live(c.conn, "/subscriptions/import")

    upload =
      file_input(view, "#opml-upload-form", :opml, [
        %{name: "bad.opml", content: "<rss/>", type: "text/xml"}
      ])

    render_upload(upload, "bad.opml")
    view |> form("#opml-upload-form") |> render_submit()
    assert has_element?(view, "#opml-error", "valid OPML")
    refute has_element?(view, "#import-opml")
    assert Library.subscriptions(c.user) == []
  end
end
