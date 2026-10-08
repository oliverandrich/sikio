# SPDX-License-Identifier: AGPL-3.0-or-later

# Adapted from ChapishoWeb.Locale with the author's permission (MIT).
defmodule SikioWeb.Locale do
  @moduledoc """
  Sets the locale per HTTP request from `Accept-Language`, else the configured default.

  Run the plug after `fetch_session`, which it writes to.
  Add `{SikioWeb.Locale, :set}` to the `on_mount` hooks of each `live_session`.
  The session carries the request's locale into the LiveView.
  The first supported base language wins. q-values are ignored, as in Chapisho's parser.
  """
  @behaviour Plug

  import Plug.Conn

  alias SikioWeb.Gettext, as: Backend

  @doc "Returns the configured, non-empty list of supported locale codes."
  defdelegate locales, to: Sikio.Preferences

  @doc "Returns the Gettext backend's configured default locale."
  def default_locale, do: Backend.__gettext__(:default_locale)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    locale = resolve(accept_language(conn))
    Gettext.put_locale(Backend, locale)
    conn |> assign(:locale, locale) |> put_session("locale", locale)
  end

  @doc "Sets the session's locale in the LiveView process, else the default."
  def on_mount(:set, _params, session, socket) do
    locale = if session["locale"] in locales(), do: session["locale"], else: default_locale()
    Gettext.put_locale(Backend, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  @doc "Resolves the locale from `Accept-Language`, for requests outside the browser pipeline."
  def accept_locale(conn), do: resolve(accept_language(conn))

  @doc "Returns the first supported language in the header, else the default."
  def resolve(accept_language) do
    known = locales()

    cond do
      match = pick_accepted(accept_language, known) -> match
      default_locale() in known -> default_locale()
      true -> hd(known)
    end
  end

  defp accept_language(conn) do
    case get_req_header(conn, "accept-language") do
      [value | _] -> value
      _ -> ""
    end
  end

  defp pick_accepted(header, known) do
    header
    |> String.split(",")
    |> Enum.map(&base_language/1)
    |> Enum.find(&(&1 in known))
  end

  defp base_language(tag) do
    tag
    |> String.split(";")
    |> hd()
    |> String.trim()
    |> String.split("-")
    |> hd()
    |> String.downcase()
  end
end
