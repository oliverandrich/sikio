# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AudioFaceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SikioWeb.AudioFace

  @chapters [
    %{at: 0, title: "Intro"},
    %{at: 900, title: "Interview"},
    %{at: 1800, title: "Listener mail"}
  ]

  defp face(assigns), do: render_component(&AudioFace.audio_face/1, assigns)

  defp marks(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-audio-mark]:not([hidden])")
    |> Enum.map(&{LazyHTML.attribute(&1, "data-at"), LazyHTML.attribute(&1, "data-title")})
    |> Enum.map(fn {[at], [title]} -> {at, title} end)
  end

  # A chapter at 0 gets no mark, since the bar starts there. Later chapters get a mark.
  test "a chapter marks where it begins on the bar, the first one aside" do
    html = face(length: 3600, position: 0, chapters: @chapters)

    # Marks are not buttons. The bar beneath handles clicks and drags.
    refute html =~ "<button data-audio-mark"

    assert marks(html) == [{"900", "Interview"}, {"1800", "Listener mail"}]
    assert html =~ "--at: 0.25"
    assert html =~ "--at: 0.5"
  end

  # Passed marks carry `data-played`, so CSS can colour them against the played part of the bar.
  test "a mark the thumb has passed says so" do
    html = face(length: 3600, position: 1000, chapters: @chapters)
    played = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-audio-mark][data-played]")
    assert Enum.map(played, &LazyHTML.attribute(&1, "data-at")) == [["0"], ["900"]]
  end

  test "the time line names the chapter that is playing" do
    html = face(length: 3600, position: 1000, chapters: @chapters)

    [label] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-audio-chapter]") |> Enum.to_list()

    assert LazyHTML.text(label) =~ "Interview"
  end

  # Mark positions are fractions of the length. Until the player reports a length, none render.
  test "no marks before the length is known, and none without chapters" do
    assert marks(face(position: 0, chapters: @chapters)) == []
    assert marks(face(length: 3600, position: 0)) == []
  end
end
