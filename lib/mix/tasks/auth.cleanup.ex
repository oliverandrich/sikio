# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Mix.Tasks.Auth.Cleanup do
  @moduledoc "Run explicitly or from an application-owned scheduler; reports deletion counts."
  @shortdoc "Deletes expired auth records; starts no scheduler"
  use Mix.Task

  @impl true
  def run([]) do
    Mix.Task.run("app.start")
    Mix.shell().info(inspect(Sikio.AuthCleanup.run()))
  end
end
