# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ChaptersTest do
  @moduledoc """
  Tests chapter parsing from show notes, using formats found in real feeds.
  """
  use ExUnit.Case, async: true

  alias Sikio.Chapters

  # PeerTube writes HTML: one paragraph, one line per chapter, `m:ss` stamps.
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

  # YouTube writes plain text: `hh:mm:ss` stamps and a dash before the title.
  # The first stamp may be above zero.
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

  # A second stamp inside one line starts the next chapter. This covers a missing line break.
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

  # Many podcasts list chapters as `<li>` items. The emptied list is removed.
  test "chapters in a list leave no empty items behind" do
    notes = "<p>Vorab.</p><ul><li>00:00 A</li><li>01:00 B</li><li>02:00 C</li></ul>"
    assert {chapters, rest} = Chapters.split(notes, :html, nil)
    assert length(chapters) == 3
    assert String.trim(rest) == "<p>Vorab.</p>"
  end

  # A heading, block or list may directly precede the first chapter.
  test "the first chapter after a heading or a block is read as well" do
    for before <- ["<h3>Kapitel</h3>", "<div>Kapitel</div>", "<ul><li>x</li></ul>"] do
      notes = before <> "<p>00:00 A<br>01:00 B<br>02:00 C</p>"
      assert {chapters, rest} = Chapters.split(notes, :html, nil)
      assert Enum.map(chapters, & &1.title) == ["A", "B", "C"], before
      refute rest =~ "00:00"
    end
  end

  # Podcasting 2.0 chapters JSON: `startTime` in seconds and `title`. `toc: false` entries are
  # skipped.
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

  # Notes are UTF-8. Line break detection must not match inside a multibyte character.
  # The last byte of ✅ is 0x85, the NEL control.
  test "characters whose bytes resemble a line break are left whole" do
    notes = "✅ Was am 29. September geschah\n✅ Warum ein Papier\n…und mehr"
    assert Chapters.split(notes, :text, nil) == {[], notes}
    assert Chapters.split("<p>" <> notes <> "</p>", :html, nil) == {[], "<p>" <> notes <> "</p>"}
  end

  # A chapter list needs at least three ascending stamps within the duration.
  # Otherwise the notes stay unchanged.
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
