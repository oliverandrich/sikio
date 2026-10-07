# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ErrorHTML do
  @moduledoc """
  Renders error responses for HTML requests.

  See config/config.exs.
  """
  use SikioWeb, :html

  # Custom error pages need the `embed_templates/1` call below and templates such as:
  #
  #   * lib/sikio_web/controllers/error_html/404.html.heex
  #   * lib/sikio_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  # Returns the status message as plain text, e.g. "Not Found" for "404.html".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
