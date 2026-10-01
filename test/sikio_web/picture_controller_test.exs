# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PictureControllerTest do
  use SikioWeb.ConnCase, async: true

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias SikioWeb.Pictures

  import Sikio.DataCase, only: [unique: 0, unique_username: 0]
  import Sikio.PictureFixtures

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))

    serving(fn
      "/missing" <> _ -> nil
      _ -> {"image/jpeg", jpeg()}
    end)

    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user)}
  end

  # Each test names its own address, so the shared cache never answers for another test.
  defp picture_url(name), do: "https://img.example.org/#{name}-#{unique()}.jpg"

  test "a signed reference is answered with the picture, from this host", %{conn: conn} do
    response = get(conn, Pictures.path([picture_url("one")]))

    assert response.status == 200
    assert response.resp_body == jpeg()
    assert get_resp_header(response, "content-type") == ["image/jpeg"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert [cache] = get_resp_header(response, "cache-control")
    assert cache =~ "private"
  end

  # Unsigned, this would fetch any address on a stranger's behalf.
  test "a reference that was not signed here is refused without fetching", %{conn: conn} do
    "/pictures/" <> ref = Pictures.path([picture_url("two")])
    # A character in the middle of the signature: the last one carries padding bits that a
    # decoder ignores, so changing it may change nothing.
    [protected, payload, signature] = String.split(ref, ".")
    {head, <<char, tail::binary>>} = String.split_at(signature, 10)
    flipped = if char == ?A, do: ?B, else: ?A
    forged = Enum.join([protected, payload, head <> <<flipped>> <> tail], ".")

    assert get(conn, "/pictures/#{forged}").status == 404
    assert get(conn, "/pictures/not-a-reference").status == 404
    refute_received {:fetched, _}
  end

  test "a picture that cannot be had sends the browser to the fallback", %{conn: conn} do
    response =
      get(
        conn,
        Pictures.path(["https://img.example.org/missing-#{unique()}.jpg"], "/images/sikio.svg")
      )

    assert redirected_to(response) == "/images/sikio.svg"
  end

  # The browser caches by address, so the same picture has to keep the same one.
  test "the same picture always has the same address" do
    url = picture_url("three")
    assert Pictures.path([url]) == Pictures.path([url])
  end

  test "pictures are only served to members" do
    response = get(build_conn(), Pictures.path([picture_url("four")]))

    assert redirected_to(response) == "/login"
  end
end
