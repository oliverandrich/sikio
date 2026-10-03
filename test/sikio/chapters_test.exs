# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ChaptersTest do
  @moduledoc """
  Chapters as publishers write them into a description, in the shapes the sources really use.
  """
  use ExUnit.Case, async: true

  alias Sikio.Chapters

  # A PeerTube instance writes markup: one paragraph, a line each, minutes and seconds.
  test "reads chapters from markup and leaves the rest of the notes" do
    notes = """
    <p>Ständig hört man von Rekorden.</p><p>0:00 Intro<br />1:58 Akkus, LFP &amp; AGM<br />4:51 Solarpanels<br />18:40 Outro</p><p>Mehr auf ct.de</p>
    """

    assert {chapters, rest} = Chapters.split(notes, :html, 1121)

    assert chapters == [
             %{at: 0, title: "Intro"},
             %{at: 118, title: "Akkus, LFP & AGM"},
             %{at: 291, title: "Solarpanels"},
             %{at: 1120, title: "Outro"}
           ]

    assert String.trim(rest) == "<p>Ständig hört man von Rekorden.</p><p>Mehr auf ct.de</p>"
  end

  # YouTube writes text: hours always, a dash before the title, a first chapter just after zero.
  test "reads chapters from text with hours and a dash" do
    notes = """
    Dennis ist zu Gast.

    00:00:08 - Hallo Nora!
    00:00:42 - Polarisierung und Diskussionskultur
    00:09:36 - Christian Wolf von TikTok gesperrt

    Mehr: https://ct.de
    """

    assert {chapters, rest} = Chapters.split(notes, :text, 3600)
    assert Enum.map(chapters, & &1.at) == [8, 42, 576]
    assert hd(chapters).title == "Hallo Nora!"
    refute rest =~ "00:00"
    assert rest =~ "Dennis ist zu Gast."
    assert rest =~ "Mehr: https://ct.de"
  end

  # A publisher who lost a line break: the second stamp inside a line starts the next chapter.
  test "a stamp with a dash inside a line starts another chapter" do
    notes = "00:00:02 - Hallo!\n00:00:47 - 80er-Ästhetik 00:05:03 - Metas Muse\n00:09:51 - Abgang"

    assert {chapters, _rest} = Chapters.split(notes, :text, nil)

    assert Enum.map(chapters, &{&1.at, &1.title}) == [
             {2, "Hallo!"},
             {47, "80er-Ästhetik"},
             {303, "Metas Muse"},
             {591, "Abgang"}
           ]
  end

  test "a dash or brackets around the stamp are read as well" do
    notes = "<p>(0:00) Start<br>[2:10] - Mitte<br>12:34 – Ende</p>"
    assert {chapters, _} = Chapters.split(notes, :html, nil)
    assert Enum.map(chapters, &{&1.at, &1.title}) == [{0, "Start"}, {130, "Mitte"}, {754, "Ende"}]
  end

  # Many podcasts list chapters as list items. The list goes with them, not empty bullets.
  test "chapters in a list leave no empty items behind" do
    notes = "<p>Vorab.</p><ul><li>00:00 A</li><li>01:00 B</li><li>02:00 C</li></ul>"
    assert {chapters, rest} = Chapters.split(notes, :html, nil)
    assert length(chapters) == 3
    assert String.trim(rest) == "<p>Vorab.</p>"
  end

  # A heading, a block or a list may end the line before the first chapter.
  test "the first chapter after a heading or a block is read as well" do
    for before <- ["<h3>Kapitel</h3>", "<div>Kapitel</div>", "<ul><li>x</li></ul>"] do
      notes = before <> "<p>00:00 A<br>01:00 B<br>02:00 C</p>"
      assert {chapters, rest} = Chapters.split(notes, :html, nil)
      assert Enum.map(chapters, & &1.title) == ["A", "B", "C"], before
      refute rest =~ "00:00"
    end
  end

  # Podcasting 2.0's file: a start in seconds and a title; a chapter marked toc false is hidden.
  test "reads a podcast's chapters file" do
    json =
      ~s|{"version":"1.2.0","chapters":[{"startTime":0,"title":"Pferde","img":"x"},| <>
        ~s|{"startTime":118.5,"title":"Akkus"},{"startTime":200,"title":"versteckt","toc":false},| <>
        ~s|{"startTime":291,"title":"Solar"}]}|

    assert Chapters.from_json(json) == [
             %{"at" => 0, "title" => "Pferde"},
             %{"at" => 118, "title" => "Akkus"},
             %{"at" => 291, "title" => "Solar"}
           ]
  end

  test "a chapters file that is not one reads as no chapters" do
    for body <- [
          "",
          "[]",
          ~s|{"chapters":"x"}|,
          ~s|{"chapters":[{"title":"no start"}]}|,
          "<html>"
        ] do
      assert Chapters.from_json(body) == []
    end
  end

  # Notes are UTF-8. A line break is never found inside a character, whose bytes may look like
  # one: the check mark ✅ ends in the byte of a next-line control.
  test "characters whose bytes resemble a line break are left whole" do
    notes = "✅ Was am 29. September geschah\n✅ Warum ein Papier\n…und mehr"
    assert Chapters.split(notes, :text, nil) == {[], notes}
    assert Chapters.split("<p>" <> notes <> "</p>", :html, nil) == {[], "<p>" <> notes <> "</p>"}
  end

  # Only a list that reads unmistakably as chapters is taken: three at least, rising, within the
  # item's length. Anything less is somebody's sentence, and the notes stay as they were.
  test "anything less than a clear chapter list is left in the notes" do
    two = "0:00 Intro\n5:00 Outro"
    falling = "0:00 Intro\n9:00 Mitte\n5:00 Outro"
    too_long = "0:00 Intro\n5:00 Mitte\n90:00 Outro"
    a_sentence = "Wir treffen uns\n18:30 Uhr am Bahnhof\nund gehen essen."

    for notes <- [two, falling, too_long, a_sentence] do
      assert Chapters.split(notes, :text, 3600) == {[], notes}
    end

    assert Chapters.split(nil, :html, nil) == {[], nil}
  end
end
