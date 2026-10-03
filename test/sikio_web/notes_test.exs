# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.NotesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import SikioWeb.Notes

  describe "notes/1" do
    # A bare string carrying markup is escaped by HEEx, and the reader meets the tags as text.
    # Nothing warns about it, so the return type is what has to carry the decision.
    test "answers with markup a template will render rather than escape" do
      assert {:safe, _} = notes("<p>Hello</p>", :html)
    end

    test "keeps the structure a publisher writes show notes with" do
      html = rendered(~s|<p>Chapters:</p><ul><li><a href="https://example.org">One</a></li></ul>|)

      assert html =~ "<p>Chapters:</p>"
      assert html =~ "<li>"
      assert html =~ ~s(href="https://example.org")
    end

    test "drops a script a feed smuggled into its notes" do
      html = rendered(~s|<p>Hello</p><script>alert(1)</script>|)

      assert html =~ "Hello"
      refute html =~ "<script"
      refute html =~ "alert(1)"
    end

    # The policy allows inline scripts, so an attribute handler that survived here would run.
    test "drops event handlers and javascript targets" do
      html = rendered(~s|<a href="javascript:alert(1)" onclick="alert(2)">Tap</a>|)

      refute html =~ "onclick"
      refute html =~ "javascript:"
    end

    test "an item without notes has nothing to render" do
      assert notes(nil, :html) == nil
      assert notes("", :html) == nil
      assert notes("", :text) == nil
    end
  end

  describe "notes/2 for plain text" do
    test "shows the brackets a publisher wrote rather than swallowing them" do
      assert rendered("5 < 6 and counting", :text) =~ "5 &lt; 6 and counting"
    end

    test "keeps the lines a chapter list depends on" do
      html = rendered("Chapters:\n00:00 One\n01:00 Two", :text)

      assert html =~ "<p>Chapters:</p>"
      assert html =~ "<p>00:00 One</p>"
    end

    # YouTube writes addresses as plain text. They become links, opening in a tab of their own;
    # a full stop or a closing bracket after one is the sentence's, not the address's.
    test "an address in text becomes a link" do
      html =
        rendered(
          "Unterschrift: https://www.tbsnews.net/world/accord-1558996.\n" <>
            "(siehe https://example.org/a?b=1&c=2) und https://de.wikipedia.org/wiki/Foo_(Bar).",
          :text
        )

      assert html =~
               ~s|<a href="https://www.tbsnews.net/world/accord-1558996" target="_blank" rel="noopener noreferrer">https://www.tbsnews.net/world/accord-1558996</a>.|

      assert html =~ ~s|<a href="https://example.org/a?b=1&amp;c=2"|
      assert html =~ ~s|>https://example.org/a?b=1&amp;c=2</a>)|
      assert html =~ ~s|href="https://de.wikipedia.org/wiki/Foo_(Bar)"|
    end

    # The text is escaped before it is linked, so an address may end in an entity. Trimming
    # punctuation never cuts into one.
    test "an address ending in an ampersand keeps it whole" do
      html = rendered("https://x.com/q?x=1& done", :text)
      assert html =~ ~s|href="https://x.com/q?x=1&amp;"|
      refute html =~ "&amp;amp"
    end

    test "only the web's addresses become links" do
      html = rendered("javascript:alert(1) und ftp://example.org und mailto:a@b.c", :text)
      refute html =~ "<a "
    end

    test "text that would be markup is shown, not run" do
      html = rendered("<script>alert(1)</script>", :text)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "pictures and links inside notes" do
    # The policy refuses a publisher's host, so a picture comes from this one or not at all.
    test "a picture is shown through Sikio's own host" do
      html = rendered(~s|<p><img src="https://img.example.org/chapter.jpg" alt="Map"></p>|)
      [src] = html |> Floki.parse_fragment!() |> Floki.attribute("img", "src")

      assert "/pictures/" <> reference = src

      # Inside running text a picture that cannot be had disappears; a placeholder tile would
      # stretch across the column.
      assert {:ok, {["https://img.example.org/chapter.jpg"], "/images/nothing.svg"}} =
               SikioWeb.Pictures.verify(reference)

      assert html =~ ~s(alt="Map")
      assert html =~ ~s(loading="lazy")
    end

    # Without the feed's own address there is no base to resolve a relative path against, and
    # plain http would be fetched in the clear on the reader's behalf.
    test "a picture whose address cannot be checked is left out" do
      html =
        rendered(
          ~s|<p>Before<img src="art/1.jpg"><img src="http://img.example.org/1.jpg">After</p>|
        )

      refute html =~ "<img"
      assert html =~ "Before"
      assert html =~ "After"
    end

    # Following a link in place would leave the page, and the dock playing in it with it.
    test "a link opens beside the reader" do
      html = rendered(~s|<p><a href="https://example.org">Site</a></p>|)

      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
    end
  end

  # Notes that are empty once filtered are no notes, so the reader is told rather than shown a
  # bare rule.
  test "notes left empty by filtering are no notes" do
    assert notes(~s|<p><img src="http://cdn.example.org/x.jpg"></p>|, :html) == nil
    assert notes("<p> </p><div></div>", :html) == nil
  end

  defp rendered(description, format \\ :html) do
    description |> notes(format) |> Phoenix.HTML.safe_to_string()
  end
end
