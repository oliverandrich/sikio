# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.BrowserPool do
  @moduledoc """
  One Chrome session that the browser features take turns on.

  Starting Chrome costs about 0.3 s and ending it 0.05 s, which was most of a typical feature.
  The features run one at a time in the sandbox's shared mode, so one session serves them all,
  reset to a blank page and an empty origin before each. It belongs to this process rather than
  to a test, because Wallaby ends a session when the test that started it ends.

  It carries no sandbox metadata in its user agent: that would name the first test's process,
  long gone by the next. The shared mode lets every process use the test's connection instead.
  """
  use Agent

  @window {1280, 800}

  def start_link(_opts \\ []), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "A session reset for the next feature, started on first use and again if it broke."
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

  @doc "Ends the session, once the suite is done."
  def stop do
    Agent.get(__MODULE__, fn session -> session && Wallaby.Chrome.end_session(session) end)
  end

  defp fresh do
    {:ok, session} = Wallaby.Chrome.start_session([])
    session
  end

  # Everything a feature may leave behind: the page and its timers, cookies and storage for the
  # test host, an emulated colour scheme or device, virtual passkeys, the window's size.
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
