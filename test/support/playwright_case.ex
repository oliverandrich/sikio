# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlaywrightCase do
  @moduledoc """
  Case template for browser features in Playwright's Chrome for Testing.

  The features also cover `priv/static/ithibati.js`, the client half of Ithibati.
  `Phoenix.LiveViewTest` cannot run them. A passkey ceremony needs `navigator.credentials`,
  a `fetch` that sets a cookie, and a redirect followed by the hook.

  Each feature gets a new browser context in a pooled browser.
  A context starts with no cookies, storage or emulation, so nothing carries over between features.
  The sandbox runs in shared mode, so tests can query what a ceremony stored.

  Per feature, `@tag browser_context_opts: [...]` sets the locale, viewport or colour scheme.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import PhoenixTest
  import PhoenixTest.Playwright, only: [add_session_cookie: 3]

  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Sessions
  alias Ithibati.Web.Gate
  alias PhoenixTest.Playwright.Config
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Frame
  alias Sikio.Accounts.User
  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo
  alias SikioWeb.Endpoint

  using do
    quote do
      use PhoenixTest.Playwright.Case

      # The PostgreSQL pass excludes `:feature`.
      @moduletag :feature

      setup do
        SikioWeb.PlaywrightCase.room_for_the_suites_own_codes()
        :ok
      end

      setup context, do: SikioWeb.PlaywrightCase.nobody_answers(context)
      setup %{conn: conn}, do: SikioWeb.PlaywrightCase.fail_on_page_errors(conn)

      import SikioWeb.PlaywrightCase

      alias Sikio.Accounts.User
      alias Sikio.Repo
    end
  end

  @doc """
  Returns a PeerTube video without image, with a long description.

  Its instance's API names a file on the instance. The browser blocks the instance's host,
  so the file fails to load and no request leaves the test.
  """
  def video_with_notes(conn, account) do
    {:ok, preview} = Parser.parse(FeedFixtures.peertube(), FeedFixtures.peertube_feed_url())
    {:ok, subscription} = Library.subscribe(account, preview)
    [video] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    notes = String.duplicate("<p>Something worth reading while it plays.</p>", 40)
    file = "https://video.example.org/static/web-videos/v-720.mp4"

    Sikio.PictureFixtures.serving(%{
      "/api/v1/videos/mSh0rtUu1d" =>
        {"application/json", Jason.encode!(%{files: [%{resolution: %{id: 720}, fileUrl: file}]})}
    })

    command(conn, "Network.enable", %{})
    command(conn, "Network.setBlockedURLs", %{urls: ["https://video.example.org/*"]})

    Repo.update!(
      Ecto.Changeset.change(video,
        audio_url: nil,
        image_url: nil,
        description: notes,
        description_format: :html
      )
    )
  end

  @doc "Returns an entry's path in the unfiltered library list, as `SikioWeb.LibraryPaths` builds it."
  def item_path(entry), do: SikioWeb.ConnCase.item_path(entry)

  @doc """
  Visits `path` and waits until the LiveView is connected.

  Use it instead of `visit/2` before interacting with the page.
  The HTTP response arrives before the socket connects.
  Until then `phx-submit` is not bound and the mount patch has not run.
  A click has no effect. A `data-` attribute changed beforehand is reset to the template value.
  """
  def open(conn, path) do
    conn |> visit(path) |> connected()
  end

  @doc """
  Raises the setup and ceremony rate limits for one browser test.

  Every test that creates an account spends a code at the real endpoint.
  Browser requests cannot get distinct addresses, so all share the loopback rate-limit counter.
  The default budget of ten per minute would reject the suite.
  The sign-in features run more than a hundred ceremonies a minute.

  Only these tests need it. Other tests write the proof into the session directly.
  The rate limiter's own test sets its own budget and address.
  """
  def room_for_the_suites_own_codes do
    Sikio.TestConfig.put_budget(:setup, {1000, 60})
    # Each sign-up is a passkey ceremony from the same loopback address and needs the same raise.
    Sikio.TestConfig.put_budget(:ceremony, {1000, 60})
  end

  @doc """
  Stubs every outgoing `Sikio.Feeds.HTTP` request with a 404 until a test sets its own stub.

  The server fetches source images in its own request process, which belongs to no test.
  A private `Req.Test` stub does not reach that process, and the request raises.
  Features run sequentially, so the stub is set to shared mode for one feature.
  An async feature would share the stub with concurrent tests, so it raises `ArgumentError`.
  """
  def nobody_answers(context) do
    if context[:async], do: raise(ArgumentError, "a browser feature cannot run async")
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    Req.Test.stub(Sikio.Feeds.HTTP, &Plug.Conn.send_resp(&1, 404, ""))
    :ok
  end

  @doc """
  Creates an account named `username` and signs the browser in by session cookie.
  Returns the account.

  The passkey ceremony takes about as long as the rest of a typical test.
  Sign-in tests run the ceremony themselves. All other features start here.
  The cookie is the endpoint's session cookie and holds an Ithibati session token.
  The page and its socket load the account as after a real sign-in.
  """
  def signed_in(conn, username) do
    account = Repo.insert!(User.changeset(%User{}, %{username: username}))
    token = Sessions.generate_session_token(account)

    add_session_cookie(conn, [value: %{Gate.session_key() => token}], Endpoint.session_options())

    account
  end

  @doc """
  Submits a setup code and leaves the browser on the claim form.

  Claiming an instance takes two forms: the setup code, then the name.
  Tests about later steps also submit the code, so the suite exercises the gate.
  """
  def code_entered(conn) do
    {:ok, code} = Instance.issue_code()

    conn
    |> fill_in("Setup code", with: code)
    |> click_button("Continue")
    |> assert_has("#claim-form")
    |> connected()
  end

  @doc """
  Fails the feature after it ends if the page had an uncaught error.

  Playwright reports these errors as events of the browser context, which no assertion sees.
  A hook that throws would otherwise leave the feature green while its selectors still match.
  The collector is not linked, because `on_exit` runs after the test process has exited.
  The check runs before the browser context closes, because `on_exit` callbacks run in reverse order.
  """
  def fail_on_page_errors(%{context_id: context}) do
    collector = spawn(fn -> collect_page_errors([]) end)
    :ok = Connection.subscribe(connection(), collector, context)

    on_exit(fn ->
      send(collector, {:page_errors, self()})

      receive do
        {:page_errors, []} -> :ok
        {:page_errors, errors} -> flunk("the page threw:\n\n" <> Enum.join(errors, "\n\n"))
      after
        timeout() ->
          Process.exit(collector, :kill)
          flunk("the page error collector did not answer")
      end
    end)
  end

  defp collect_page_errors(errors) do
    receive do
      {:playwright_msg, %{method: :page_error, params: params}} ->
        collect_page_errors([page_error_message(params) | errors])

      {:page_errors, pid} ->
        send(pid, {:page_errors, Enum.reverse(errors)})

      _other ->
        collect_page_errors(errors)
    end
  end

  defp page_error_message(%{error: %{error: %{message: message}}}), do: message
  defp page_error_message(params), do: inspect(params)

  @doc """
  Claims the instance as `username` with a passkey and leaves the browser on the recovery codes.

  Adds the virtual authenticator first, for features whose subject comes after signing up.
  """
  def claimed(conn, username) do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> code_entered()
    |> fill_in("Username", with: username)
    |> click_button("Create your passkey")
    |> assert_path("/recovery-codes")
  end

  @doc """
  Waits until the current page's LiveView is connected.

  For a page reached by a click instead of `open/2`.
  A full page load serves the document before the socket connects.
  A `phx-click` has no effect until the LiveView has joined.
  """
  def connected(conn), do: assert_has(conn, "[data-phx-main].phx-connected")

  @doc """
  Runs `body` as a JavaScript function in the page and passes its result to `fun`.

  The body may `return` a value or a Promise and reads `arguments[0]` and on.
  `args` are those arguments.
  """
  def script(conn, body, args \\ [], fun \\ &Function.identity/1)

  def script(conn, body, fun, _) when is_function(fun, 1), do: script(conn, body, [], fun)

  def script(conn, body, args, fun) do
    fun.(value_of(conn, body, args))
    conn
  end

  @doc "Returns what `script/4` would pass on, for a value the test keeps."
  def value_of(%{frame_id: frame}, body, args \\ []) do
    case Frame.evaluate(frame,
           expression: "args => (function () {\n#{body}\n}).apply(null, args)",
           is_function: true,
           arg: args,
           timeout: timeout()
         ) do
      {:ok, value} -> value
      {:error, error} -> flunk("the script failed: #{inspect(error)}\n\n#{body}")
    end
  end

  @doc """
  Runs `body` as `script/4` does until it returns the expected value, or fails at the timeout.

  For page state no selector can express, such as a computed layout or a media element's time.
  Rendering may lag the DOM by a frame, so one reading is not enough.

  Options: `:equals` is the expected value, `true` by default. `:args` are the script's
  arguments. `:message` replaces the failure message.
  """
  def eventually(conn, body, opts \\ []) do
    expected = Keyword.get(opts, :equals, true)
    deadline = System.monotonic_time(:millisecond) + timeout()
    last = poll(fn -> value_of(conn, body, Keyword.get(opts, :args, [])) end, expected, deadline)

    assert last == expected,
           opts[:message] || "#{body}\n\nreturned #{inspect(last)}, wanted #{inspect(expected)}"

    conn
  end

  # Each reading is one round trip to the browser, so the loop needs no pause.
  defp poll(read, expected, deadline) do
    case read.() do
      ^expected ->
        expected

      last ->
        if System.monotonic_time(:millisecond) > deadline,
          do: last,
          else: poll(read, expected, deadline)
    end
  end

  @doc "Asserts that `selector` matches an element that is in the document but not visible."
  def assert_hidden(conn, selector) do
    assert attached?(conn, "css=#{selector} >> visible=false", false),
           "no hidden element matches #{selector}"

    conn
  end

  @doc """
  Asserts that `selector` matches an element in the document, visible or not.

  For an element without a box, such as an empty hook container.
  `assert_has/2` counts only elements with a box as visible.
  """
  def assert_attached(conn, selector) do
    assert attached?(conn, "css=#{selector}", false), "no element matches #{selector}"
    conn
  end

  @doc """
  Asserts that `selector` matches no element in the document, visible or not.

  `refute_has/2` passes for an element without a box, so it cannot show that such an element left.
  """
  def refute_attached(conn, selector) do
    refute attached?(conn, "css=#{selector}", true), "an element still matches #{selector}"
    conn
  end

  # Frame.expect waits until the expectation, negated by `is_not`, holds or the timeout passes.
  # Either way it returns whether a matching element is attached.
  defp attached?(%{frame_id: frame}, selector, is_not) do
    {:ok, held?} =
      Frame.expect(frame,
        expression: "to.be.attached",
        selector: selector <> " >> nth=0",
        is_not: is_not,
        timeout: timeout()
      )

    held?
  end

  @doc "Returns the path of the page the browser shows now."
  def current_path(conn), do: value_of(conn, "return location.pathname")

  @doc """
  Fills the field `selector` matches with `value`.

  For fields whose label a test cannot name, such as a search field labelled only by its placeholder.
  """
  def fill(%{frame_id: frame} = conn, selector, value) do
    {:ok, _} = Frame.fill(frame, selector: selector, value: value, timeout: timeout())
    conn
  end

  @doc """
  Presses each key in turn on the focused element.

  Names follow `KeyboardEvent.key`, for example `"Escape"`, `"ArrowDown"` or `"j"`.
  """
  def keys(conn, keys) do
    for key <- keys, do: page_call(conn, "keyboardPress", %{key: key})
    conn
  end

  @doc """
  Returns context options for a phone of `width` by `height` CSS pixels.
  For `@tag browser_context_opts: phone(390, 844)`.
  """
  def phone(width, height) do
    [
      viewport: %{width: width, height: height},
      device_scale_factor: 1.0,
      is_mobile: true,
      has_touch: true
    ]
  end

  @doc ~s|Emulates the system colour scheme, `"light"` or `"dark"`, for `prefers-color-scheme`.|
  def color_scheme(conn, scheme) do
    page_call(conn, "emulateMedia", %{colorScheme: scheme})
    conn
  end

  @doc "Sets the page's viewport in CSS pixels."
  def resize(conn, width, height) do
    page_call(conn, "setViewportSize", %{viewportSize: %{width: width, height: height}})
    conn
  end

  @doc """
  Adds a virtual WebAuthn authenticator to this feature's page.

  Uses Chrome's own authenticator through a CDP session.
  Playwright's `credentials` API cannot serve this library.
  Its synthetic credential returns an empty `toJSON()`, which the library uses for serialization.
  No credential is seeded. Each test registers its own passkey, so registration is covered.
  """
  def virtual_authenticator(conn) do
    command(conn, "WebAuthn.enable", %{})

    %{"authenticator_id" => id} =
      command(conn, "WebAuthn.addVirtualAuthenticator", %{
        options: %{
          protocol: "ctap2",
          # A platform authenticator such as Touch ID or Windows Hello.
          # Web application passkeys use this kind.
          transport: "internal",
          hasResidentKey: true,
          hasUserVerification: true,
          isUserVerified: true,
          automaticPresenceSimulation: true
        }
      })

    id
  end

  @doc "Removes a virtual authenticator, so a new one can model a second device."
  def remove_authenticator(conn, authenticator) do
    command(conn, "WebAuthn.removeVirtualAuthenticator", %{authenticatorId: authenticator})
    conn
  end

  # Sends a CDP command over the page's one CDP session.
  # A virtual authenticator lives only as long as the session that added it.
  # So the session is opened once per page and kept in the test process.
  # playwright_ex has no wrapper for `newCDPSession`, so the protocol method is sent by name.
  # Playwright returns CDP results with their keys in snake case.
  defp command(conn, method, params) do
    %{result: result} = send!(cdp_session(conn), :send, %{method: method, params: params})
    result
  end

  # playwright_ex has no wrapper for these page methods, so they are sent by protocol name.
  defp page_call(%{page_id: page}, method, params) do
    send!(page, method, params)
    :ok
  end

  defp cdp_session(%{context_id: context, page_id: page}) do
    with nil <- Process.get({__MODULE__, page}) do
      %{session: %{guid: session}} = send!(context, "newCDPSession", %{page: %{guid: page}})
      Process.put({__MODULE__, page}, session)
      session
    end
  end

  # Returns the reply's result. A method without a result replies without a `:result` key.
  defp send!(guid, method, params) do
    case Connection.send(connection(), %{guid: guid, method: method, params: params}, timeout()) do
      %{error: error} -> raise "#{method} failed: #{inspect(error)}"
      reply -> Map.get(reply, :result, %{})
    end
  end

  defp connection, do: PlaywrightEx.Supervisor.connection_name()
  defp timeout, do: Config.global(:timeout)
end
