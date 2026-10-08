# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :sikio

  alias Ithibati.Identity.Sessions

  # The session is stored in a signed and encrypted cookie.
  @session_options [
    store: :cookie,
    key: "_sikio_key",
    signing_salt: "PxukINKI",
    same_site: "Lax",
    encryption_salt: "mNqjztHi9zI12aLG"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  if Application.compile_env(:sikio, :sql_sandbox, false) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  # Serves `priv/static` at "/".
  # `gzip` serves files compressed by `phx.digest` when code reloading is off.
  # Tests disable it. A release build leaves compressed copies older than the test assets.
  plug Plug.Static,
    at: "/",
    from: :sikio,
    gzip: Application.compile_env(:sikio, :gzip_static, not code_reloading?),
    only: SikioWeb.static_paths(),
    # A release links these root files by digested names, such as `manifest-<hash>.webmanifest`.
    # `only` matches exact names, so the digested ones need their prefix.
    only_matching: ~w(favicon apple-touch-icon manifest),
    raise_on_missing_only: code_reloading?

  # Enabled by the endpoint's `:code_reloader` configuration.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :sikio
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  # Runs before `Plug.RequestId` and `Plug.Telemetry`, so logs show the client address.
  # Without it they show the reverse proxy's address.
  plug SikioWeb.ClientIp

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :session
  plug SikioWeb.Router

  @doc "Returns the session cookie options. Feature tests use them to write a session cookie."
  def session_options, do: @session_options

  # The cookie's `max_age` equals the session lifetime.
  # It is read per request, so runtime configuration can set it.
  defp session(conn, _opts) do
    options = Keyword.put(@session_options, :max_age, Sessions.max_age())
    Plug.Session.call(conn, Plug.Session.init(options))
  end
end
