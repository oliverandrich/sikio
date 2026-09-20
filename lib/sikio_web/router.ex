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

    # Three openings, each one the player's. `media-src` because a podcast streams from whichever
    # server published it. `frame-src` and the extra `script-src` origin because the YouTube embed
    # and its IFrame API come from YouTube, and only after somebody has pressed play.
    #
    # A fourth cannot be written here. A PeerTube video is played by the instance that holds it,
    # and any host may be one, so `SikioWeb.ContentSecurityPolicy` below adds the instances this
    # account subscribed to. This is the policy every response carries before it does.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline' https://www.youtube.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' https:; frame-src 'self' https://www.youtube-nocookie.com; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; form-action 'self'",
      "referrer-policy" => "no-referrer"
    }

    plug Ithibati.Web.Gate, :current_account
    plug SikioWeb.Locale
    # After the gate, because what it may frame depends on who is asking.
    plug SikioWeb.ContentSecurityPolicy
  end

  # Its own pipeline, not `:browser`. These endpoints answer JSON, and `:browser`'s
  # `accepts ["html"]` refuses the hook's request with a 406 before the controller is reached —
  # which is exactly how this example found the mistake in the library's README.
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

  scope "/auth" do
    pipe_through :ceremony
    # The name the passkey dialog shows, and the only thing separating this example's credentials
    # from the other's: a relying-party id is a *host*, so both examples on localhost share one
    # scope however different their databases are.
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
      on_mount: [{Ithibati.Web.Gate, {:require_account, to: "/login"}}, {SikioWeb.Locale, :set}] do
      live "/", LibraryLive
      live "/library/:id", PlayerLive
      live "/invitations", InvitationsLive
      live "/subscriptions", SubscriptionsLive
      live "/subscriptions/import", OPMLLive
      live "/account/verify", VerifyIdentityLive
      live "/account/passkeys", AccountSecurityLive, :passkeys
      live "/account/recovery-codes", AccountSecurityLive, :recovery_codes
    end

    get "/subscriptions.opml", OPMLController, :export
    get "/recovery-codes", SessionController, :recovery_codes
    delete "/session", SessionController, :sign_out
  end
end
