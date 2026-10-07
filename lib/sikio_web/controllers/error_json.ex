# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ErrorJSON do
  @moduledoc """
  Renders error responses for JSON requests.

  See config/config.exs.
  """

  # A status code can get its own clause:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # Returns the status message for the template name, e.g. "Not Found" for "404.json".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
