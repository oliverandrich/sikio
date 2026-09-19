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

    test "text that would be markup is shown, not run" do
      html = rendered("<script>alert(1)</script>", :text)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  defp rendered(description, format \\ :html) do
    description |> notes(format) |> Phoenix.HTML.safe_to_string()
  end
end
