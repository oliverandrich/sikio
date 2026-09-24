# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.StarterDrift do
  @moduledoc """
  Compares this application's copies of generated files against the templates they came from.

  Ithibati Starter generates the auth half of an application, so every file it writes exists at
  least three times: here, in Chapisho, and in the template every new project is made from.
  Nothing kept the copies together, and they drifted apart without anybody noticing — reading a
  forwarding header with `to_charlist/1` raised on bytes a visitor writes, both applications had
  it, and the template had the fix and a test for it. A fix found once, applied to one copy, and
  the other two stayed wrong until somebody diffed them.

  So something diffs them. Prose is ignored and code is not: the moduledocs are reflowed and
  reworded per application on purpose, while a differing expression is what nobody meant.
  """

  @doc "The starter's template directory, or `nil` when the dependency is not checked out."
  def templates do
    path = Path.join([File.cwd!(), "deps", "ithibati_starter", "priv", "templates", "auth"])

    if File.dir?(path), do: path
  end

  @doc """
  Every template that has a counterpart in this application, as `{template, local}` paths.

  Found rather than listed, so a file the starter grows is one this application has to classify
  rather than one it silently ignores.
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
  The code of a file, with prose, blank lines and the application's own names taken out.

  What is left is what two copies have to agree about. A module name, a licence header and the
  wording of a moduledoc are all things an application is entitled to its own version of.
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

  # `@moduledoc`/`@doc` heredocs and every comment. A `"""` inside code would confuse this, and
  # none of the generated files has one — a test says so rather than trusting it.
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
