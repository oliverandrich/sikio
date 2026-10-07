# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.BrowserPool do
  @moduledoc """
  One Chrome session shared by all browser features.

  Starting Chrome takes about 0.3 s and ending it 0.05 s, most of a typical feature's runtime.
  Features run sequentially in the sandbox's shared mode, so one session serves all of them.
  The session is reset to a blank page and a cleared origin before each feature.
  This Agent owns the session, because Wallaby ends a session when its starting test ends.

  The user agent carries no sandbox metadata.
  That metadata would name the first test's pid, which has exited by the next feature.
  Shared mode lets every process use the test's connection instead.
  """
  use Agent

  @window {1280, 800}

  def start_link(_opts \\ []), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "Returns the reset session. Starts a new one on first use or after a failed reset."
  def checkout do
    Agent.get_and_update(
      __MODULE__,
      fn session ->
        session = if session && reset?(session), do: session, else: fresh()
        {session, session}
      end,
      :infinity
    )
  end

  @doc "Ends the session after the suite."
  def stop do
    Agent.get(__MODULE__, fn session -> session && Wallaby.Chrome.end_session(session) end)
  end

  defp fresh do
    {:ok, session} = Wallaby.Chrome.start_session([])
    session
  end

  # Clears what a feature may leave: the page and its timers, cookies, the test origin's storage.
  # Also resets emulated media, device metrics, virtual authenticators and the window size.
  defp reset?(session) do
    {width, height} = @window
    session = Wallaby.Browser.visit(session, "about:blank")
    origin = SikioWeb.Endpoint.url()

    command(session, "Storage.clearDataForOrigin", %{origin: origin, storageTypes: "all"})
    command(session, "Network.clearBrowserCookies", %{})
    command(session, "Emulation.setEmulatedMedia", %{media: "", features: []})
    command(session, "Emulation.clearDeviceMetricsOverride", %{})
    command(session, "WebAuthn.disable", %{})
    Wallaby.Browser.resize_window(session, width, height)
    true
  rescue
    _ -> false
  end

  defp command(session, cmd, params) do
    {:ok, _} =
      Wallaby.HTTPClient.request(:post, "#{session.url}/chromium/send_command_and_get_result", %{
        cmd: cmd,
        params: params
      })
  end
end
