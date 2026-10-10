# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb do
  @moduledoc """
  Shared `use` definitions for routers, controllers, LiveViews and components.

      use SikioWeb, :controller
      use SikioWeb, :html

  Each quoted block is injected into every module that uses it.
  Keep the blocks to imports, uses and aliases.
  Define functions in separate modules and import them here.
  """

  def static_paths,
    do:
      ~w(assets fonts images vendor favicon.ico apple-touch-icon.png manifest.webmanifest robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: SikioWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: SikioWeb.Gettext

      import Phoenix.HTML
      import SikioWeb.CoreComponents

      alias Phoenix.LiveView.JS
      alias SikioWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SikioWeb.Endpoint,
        router: SikioWeb.Router,
        statics: SikioWeb.static_paths()
    end
  end

  @doc """
  Injects the block named by `which`, such as `:controller` or `:live_view`.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
