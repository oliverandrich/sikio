# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.BrowserDriver do
  @moduledoc """
  Locates the chromedriver for the feature tests.

  `CHROMEWEBDRIVER` takes precedence.
  GitHub runner images set it to a driver that matches their Chrome.
  Elsewhere `mise which chromedriver` supplies it.
  It is installed per machine, because it must match the local Chrome.
  `PATH` is not searched.

  A missing driver raises. Skipping the feature tests instead would silently drop their coverage.
  """

  @doc "The driver's path, or a raise that says how to get one."
  def path do
    case System.get_env("CHROMEWEBDRIVER") do
      nil -> from_mise()
      dir -> Path.join(dir, "chromedriver")
    end
  end

  defp from_mise do
    with mise when is_binary(mise) <- System.find_executable("mise"),
         {path, 0} <- System.cmd(mise, ["which", "chromedriver"], stderr_to_stdout: true) do
      String.trim(path)
    else
      _ -> raise no_driver()
    end
  end

  # The message includes Chrome's major version, which the driver version must match.
  # A mismatch fails with a session error that names neither Chrome nor the driver.
  defp no_driver do
    """
    The browser tests need a chromedriver and there is none.

        mise use --path mise.local.toml chromedriver@#{chrome_major() || "<your Chrome's major version>"}

    Into `mise.local.toml`, which is gitignored, because the version has to match the Chrome on
    *this* machine and Chrome updates itself. CI uses the runner's own through CHROMEWEBDRIVER.
    """
  end

  @chrome ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "google-chrome"]

  defp chrome_major do
    Enum.find_value(@chrome, fn candidate ->
      # `find_executable/1` accepts both an absolute path and a bare name.
      with executable when is_binary(executable) <- System.find_executable(candidate),
           {output, 0} <- System.cmd(executable, ["--version"], stderr_to_stdout: true),
           [_, major] <- Regex.run(~r/\s(\d+)\./, output) do
        major
      else
        _ -> nil
      end
    end)
  end
end
