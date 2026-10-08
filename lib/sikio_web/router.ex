# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Router do
  use SikioWeb, :router

  import Ithibati.Web.Router

  scope "/", SikioWeb do
    get "/health", HealthController, :show
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SikioWeb.Layouts, :root}
    plug :protect_from_forgery

    # Three CSP exceptions, all for the player. `media-src https:` allows podcast audio from any
    # host. `frame-src` and the extra `script-src` origin allow the YouTube embed and IFrame API.
    # The IFrame API script loads only after the first play.
    #
    # PeerTube embeds come from arbitrary hosts and cannot be listed here.
    # `SikioWeb.ContentSecurityPolicy` adds the account's subscribed instances to `frame-src`.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline' https://www.youtube.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' https:; frame-src 'self' https://www.youtube-nocookie.com; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; form-action 'self'",
      "referrer-policy" => "no-referrer"
    }

    plug Ithibati.Web.Gate, :current_account
    plug SikioWeb.Locale
    # Runs after the gate, because the added `frame-src` origins depend on the account.
    plug SikioWeb.ContentSecurityPolicy
  end

  # A separate pipeline, because these endpoints return JSON.
  # `:browser` accepts only HTML and answers the hook's JSON request with a 406.
  pipeline :ceremony do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug Ithibati.Web.Gate, :current_account
    plug SikioWeb.Locale
    plug SikioWeb.AuthRateLimit
  end

  pipeline :authenticated do
    plug Ithibati.Web.Gate, {:require_account, to: "/login"}
  end

  scope "/account", SikioWeb do
    pipe_through [:browser, :authenticated]
    get "/confirm/:purpose", AccountSecurityController, :confirm
    delete "/sessions", AccountSecurityController, :sign_out_all
    patch "/passkeys/:id", AccountSecurityController, :rename_passkey
    delete "/passkeys/:id", AccountSecurityController, :delete_passkey
    post "/recovery-codes", AccountSecurityController, :regenerate_codes
  end

  # The WebSub callback for Google's hub. It has no session, cookies or CSRF token; the hub
  # proves itself with the unguessable token and, for pushes, a signature.
  scope "/websub", SikioWeb do
    get "/:token", WebSubController, :verify
    post "/:token", WebSubController, :push
  end

  scope "/pictures", SikioWeb do
    pipe_through [:browser, :authenticated]
    get "/:ref", PictureController, :show
  end

  scope "/auth" do
    pipe_through :ceremony
    # `rp_name` is the name the passkey dialog shows.
    # The relying-party id is the host, so all apps on localhost share one passkey scope.
    ithibati_routes(handler: SikioWeb.Auth, rp_name: "Sikio")
  end

  scope "/", SikioWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{Ithibati.Web.Gate, :current_account}, {SikioWeb.Locale, :set}] do
      live "/login", SignInLive, :login
      live "/recover", SignInLive, :recover
      live "/setup", SignInLive, :setup
      live "/invite/:token", InviteLive
    end

    live_session :members,
      on_mount: [
        {Ithibati.Web.Gate, {:require_account, to: "/login"}},
        {SikioWeb.Locale, :set},
        SikioWeb.Sidebar,
        SikioWeb.LibraryEvents
      ] do
      # Library places, each with an optional item; see `SikioWeb.LibraryPaths.library_path/3`.
      live "/", LibraryLive, :index
      live "/inbox", LibraryLive, :index
      live "/inbox/:item", LibraryLive, :index
      live "/queue", LibraryLive, :index
      live "/queue/:item", LibraryLive, :index
      live "/history", LibraryLive, :index
      live "/history/:item", LibraryLive, :index
      # `/new`, `/in-progress` and `/completed` predate the inbox. `LibraryLive` patches them.
      live "/new", LibraryLive, :index
      live "/new/:item", LibraryLive, :index
      live "/in-progress", LibraryLive, :index
      live "/in-progress/:item", LibraryLive, :index
      live "/completed", LibraryLive, :index
      live "/completed/:item", LibraryLive, :index
      live "/all", LibraryLive, :index
      live "/all/:item", LibraryLive, :index
      live "/feeds/:feed", LibraryLive, :index
      live "/feeds/:feed/:place", LibraryLive, :index
      live "/feeds/:feed/:status/:item", LibraryLive, :index
      live "/tags/:tag", LibraryLive, :index
      live "/tags/:tag/:place", LibraryLive, :index
      live "/tags/:tag/:status/:item", LibraryLive, :index
      live "/library", PlacesLive
      live "/search", LibraryLive, :index
      live "/invitations", InvitationsLive
      live "/add", AddSourceLive
      live "/subscriptions", SubscriptionsLive
      live "/subscriptions/import", OPMLLive
      live "/account/verify", VerifyIdentityLive
      live "/account/settings", SettingsLive
      live "/account/passkeys", AccountSecurityLive, :passkeys
      live "/account/recovery-codes", AccountSecurityLive, :recovery_codes
    end

    # A form POST, not a LiveView event, because a LiveView cannot write to the session.
    post "/setup/code", SetupController, :create

    get "/subscriptions.opml", OPMLController, :export
    get "/recovery-codes", SessionController, :recovery_codes
    delete "/session", SessionController, :sign_out
  end
end
