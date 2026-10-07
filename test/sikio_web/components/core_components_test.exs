# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias SikioWeb.CoreComponents

  test "invalid fields use only the error border color" do
    for type <- ["text", "select", "textarea"] do
      html =
        render_component(&CoreComponents.input/1,
          type: type,
          id: "name",
          name: "name",
          value: "",
          options: [],
          errors: ["is invalid"]
        )

      assert html =~ "border-danger"
      refute html =~ "border-control"
    end
  end

  # A `class` on a button adds to its base classes. Replacing them dropped padding, focus ring
  # and colours from buttons that only set a margin.
  test "a class given to a button is added to its own" do
    html =
      render_component(&CoreComponents.button/1,
        class: "mt-5",
        variant: "primary",
        rest: %{},
        inner_block: [%{inner_block: fn _, _ -> "Go" end}]
      )

    assert html =~ "mt-5"
    assert html =~ "bg-accent"
    assert html =~ "min-h-11"
  end
end
