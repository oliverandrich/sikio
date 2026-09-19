# Adapted from ChapishoWeb.Locale with the author's permission (MIT).
defmodule SikioWeb.Locale do
  @moduledoc """
  Resolves each HTTP request from Accept-Language, then the configured default.

  Run the plug after fetching the session and (when present) the current account.
  Add `{SikioWeb.Locale, :set}` after authentication hooks in each live_session.
  The session only carries the current request language into LiveView; its first supported base language
  wins, matching Chapisho's deliberately minimal parser rather than weighting q-values.
  """
  @behaviour Plug

  import Plug.Conn

  alias SikioWeb.Gettext, as: Backend

  @doc "Configured, non-empty list of supported locale codes."
  def locales, do: Application.get_env(:sikio, :locales, ~w(en de))

  @doc "The Gettext backend's configured default."
  def default_locale, do: Backend.__gettext__(:default_locale)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    locale = resolve(accept_language(conn))
    Gettext.put_locale(Backend, locale)
    conn |> assign(:locale, locale) |> put_session("locale", locale)
  end

  @doc "Restores the locale in the LiveView process after account loading."
  def on_mount(:set, _params, session, socket) do
    locale = if session["locale"] in locales(), do: session["locale"], else: default_locale()
    Gettext.put_locale(Backend, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  @doc "Header/default fallback for requests that did not reach the browser pipeline."
  def accept_locale(conn), do: resolve(accept_language(conn))

  @doc "Picks the first supported browser language, falling back to the default."
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
