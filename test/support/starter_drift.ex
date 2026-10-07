# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.StarterDrift do
  @moduledoc """
  Compares this application's copies of generated files with the Ithibati Starter templates.

  Ithibati Starter generates the auth half of an application.
  Each generated file exists here, in Chapisho, and in the starter template.
  The copies drifted apart unnoticed.
  Example: reading a forwarding header with `to_charlist/1` raised on bytes a visitor sends.
  Both applications had the bug. The template had the fix and a test for it.

  The comparison ignores prose and compares code.
  Moduledocs are reworded per application on purpose. A differing expression is not intended.
  """

  @doc "Returns the starter's template directory, or `nil` when the dependency is not fetched."
  def templates do
    path = Path.join([File.cwd!(), "deps", "ithibati_starter", "priv", "templates", "auth"])

    if File.dir?(path), do: path
  end

  @doc """
  Returns every template with a counterpart in this application, as `{template, local}` paths.

  Templates are found by wildcard, not listed, so a new starter template is not skipped.
  """
  def pairs(root, app) do
    root
    |> Path.join("**/*.tpl")
    |> Path.wildcard()
    |> Enum.map(&{Path.relative_to(&1, root), local_path(&1, root, app)})
    |> Enum.filter(fn {_template, local} -> File.regular?(local) end)
  end

  defp local_path(template, root, app) do
    template
    |> Path.relative_to(root)
    |> String.replace_suffix(".tpl", "")
    |> String.replace("__APP___web", "#{app}_web")
    |> String.replace("__APP__", app)
  end

  @doc """
  Returns a file's code lines without prose, blank lines and the application's names.

  Copies must agree on these lines.
  Module names, the licence header and moduledoc wording may differ per application.
  """
  def code(path, app) do
    path
    |> File.read!()
    |> strip_names(app)
    |> String.split("\n")
    |> drop_prose()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_names(text, app) do
    module = app |> String.split("_") |> Enum.map_join(&String.capitalize/1)

    text
    |> String.replace("__MODULE__Web", "APPWEB")
    |> String.replace("__MODULE__", "APP")
    |> String.replace("__APP___web", "appweb")
    |> String.replace("__APP__", "app")
    |> String.replace("#{module}Web", "APPWEB")
    |> String.replace(module, "APP")
    |> String.replace("#{app}_web", "appweb")
    |> String.replace(app, "app")
  end

  # Drops `@moduledoc`/`@doc` heredocs and comment lines. A `"""` inside code would break this.
  # No generated file has one, and a test checks that.
  defp drop_prose(lines) do
    {kept, _inside} =
      Enum.reduce(lines, {[], false}, fn line, {kept, inside} ->
        trimmed = String.trim(line)

        cond do
          inside and trimmed == ~s(""") -> {kept, false}
          inside -> {kept, true}
          String.starts_with?(trimmed, "#") -> {kept, false}
          String.ends_with?(trimmed, ~s(""")) and doc_opener?(trimmed) -> {kept, true}
          true -> {[line | kept], false}
        end
      end)

    Enum.reverse(kept)
  end

  defp doc_opener?(line),
    do: String.starts_with?(line, "@moduledoc") or String.starts_with?(line, "@doc")
end
