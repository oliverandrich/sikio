# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTransferTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Phoenix.LiveViewTest

  alias Sikio.Library.Events
  alias Sikio.Library.Transfer
  alias Sikio.Library.TransferImport

  setup :sign_in_with_episode

  test "the library export is an authenticated JSON download of the current account", c do
    conn = get(c.conn, "/library.json")
    document = Jason.decode!(response(conn, 200))

    assert %{"format" => "sikio-account", "version" => 1} = document
    assert [%{"url" => url, "kind" => "podcast"}] = document["subscriptions"]
    assert url == c.sub.feed.url
    assert [%{"external_id" => "episode-1", "status" => "new"}] = document["entries"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="sikio-library.json")
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert build_conn() |> get("/library.json") |> redirected_to() == "/login"
  end

  test "the subscriptions page links to moving the library", c do
    {:ok, view, _} = live(c.conn, "/subscriptions")
    assert has_element?(view, "#library-transfer-link[href='/subscriptions/library']")
  end

  test "an uploaded export starts an import and its summary arrives later", c do
    {:ok, view, _} = live(c.conn, "/subscriptions/library")
    assert has_element?(view, "#library-export-link[href='/library.json']")

    upload(view, "{")
    assert has_element?(view, "#library-error")
    refute_enqueued(worker: TransferImport)

    upload(view, c.user |> Transfer.export() |> Jason.encode!())
    assert has_element?(view, "#library-started")
    assert_enqueued(worker: TransferImport, args: %{user_id: c.user.id})

    summary = %{
      subscriptions: %{imported: 2, existing: 1, failed: ["https://gone.example.org/rss"]},
      entries: %{restored: 7, kept: 2, missing: 3}
    }

    Events.imported(c.user, {:ok, summary})
    assert has_element?(view, "#library-summary", "2")
    assert has_element?(view, "#library-failed", "https://gone.example.org/rss")
    refute has_element?(view, "#library-started")
  end

  test "an import that fails is reported, not left running", c do
    {:ok, view, _} = live(c.conn, "/subscriptions/library")
    upload(view, c.user |> Transfer.export() |> Jason.encode!())
    assert has_element?(view, "#library-started")

    Events.imported(c.user, :error)
    assert has_element?(view, "#library-error")
    refute has_element?(view, "#library-started")
  end

  # The account's other pages and the player get no message about the import.
  test "a finished import leaves the account's open pages running", c do
    {:ok, library, _} = live(c.conn, "/")
    {:ok, subscriptions, _} = live(c.conn, "/subscriptions")
    {:ok, dock, _} = live_isolated(c.conn, SikioWeb.PlayerDockLive)
    {:ok, job} = Transfer.start(c.user, c.user |> Transfer.export() |> Jason.encode!())
    Req.Test.stub(Sikio.Feeds.HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    assert :ok = perform_job(TransferImport, job.args)
    for view <- [library, subscriptions, dock], do: assert(render(view))
  end

  defp upload(view, json) do
    file =
      file_input(view, "#library-upload-form", :library, [
        %{name: "sikio-library.json", content: json, type: "application/json"}
      ])

    render_upload(file, "sikio-library.json")
    view |> form("#library-upload-form") |> render_submit()
  end
end
