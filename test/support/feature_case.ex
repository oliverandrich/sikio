# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.FeatureCase do
  @moduledoc """
  Case template for Wallaby features in Chrome.

  The features also cover `priv/static/ithibati.js`, the client half of Ithibati.
  `Phoenix.LiveViewTest` cannot run them. A passkey ceremony needs `navigator.credentials`,
  a `fetch` that sets a cookie, and a redirect followed by the hook.

  Wallaby shares the test's sandboxed connection with the server.
  Tests can query the database to assert that a ceremony was stored, not only that a page changed.
  """
  use ExUnit.CaseTemplate

  # `using` imports this for test modules. This module imports it too.
  # `assert_has/2` is a macro that expands to `execute_query/2`, so both must be in scope here.
  import Wallaby.Browser

  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Sessions
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo
  alias SikioWeb.BrowserPool
  alias SikioWeb.Endpoint
  alias Wallaby.Feature.Utils
  alias Wallaby.Query

  using do
    quote do
      # Wallaby.Feature without its setup, which starts a new Chrome per feature.
      # See sessions/1 below.
      ExUnit.Case.register_attribute(__MODULE__, :sessions)
      use Wallaby.DSL
      import Wallaby.Feature

      setup context, do: SikioWeb.FeatureCase.sessions(context)

      setup %{session: session} do
        SikioWeb.FeatureCase.language(session, "en")
        SikioWeb.FeatureCase.room_for_the_suites_own_codes()
        :ok
      end

      setup context, do: SikioWeb.FeatureCase.nobody_answers(context)

      import SikioWeb.FeatureCase
      import Wallaby.Query

      alias Sikio.Accounts.User
      alias Sikio.Repo
    end
  end

  @doc """
  Asserts that nothing matches `query`. Retries until the count is zero, passes at once if it is.

  Wallaby's `refute_has/2` waits the full `max_wait_time` when the element is absent.
  It fails at once when the element is present and not yet removed.
  To check that an action shows nothing, first assert what the action does show.
  """
  def gone(session, query), do: Wallaby.Browser.assert_has(session, Wallaby.Query.count(query, 0))

  @doc """
  Setup callback that returns the browser session.

  The default is the shared `SikioWeb.BrowserPool` session, reset.
  A feature with `@sessions`, for example for a phone, gets new sessions with those capabilities.
  """
  def sessions(context) do
    metadata = Utils.maybe_checkout_repos(context[:async])

    case get_in(context, [:registered, :sessions]) do
      nil ->
        session = BrowserPool.checkout()
        listed_for_screenshots(session)
        %{session: session}

      sessions ->
        sessions
        |> Utils.sessions_iterable()
        |> Enum.map(&Utils.start_session(&1, metadata: metadata))
        |> Utils.build_setup_return()
    end
  end

  # Wallaby screenshots a failed feature's sessions, looked up by test pid in its session store.
  # Registering the pooled session normally would make Wallaby end it with the test.
  # So it is inserted into the public ETS table directly and removed on exit.
  # This depends on Wallaby.SessionStore's table name and key shape.
  defp listed_for_screenshots(session) do
    key = {make_ref(), session.id, self()}
    :ets.insert(:session_store, {key, session})
    on_exit(fn -> :ets.delete(:session_store, key) end)
  end

  @doc "Returns a PeerTube video embedding a Sikio URL, without image, with a long description."
  def video_with_notes(account) do
    {:ok, preview} = Parser.parse(FeedFixtures.peertube(), FeedFixtures.peertube_feed_url())
    {:ok, subscription} = Library.subscribe(account, preview)
    [video] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    notes = String.duplicate("<p>Something worth reading while it plays.</p>", 40)

    Repo.update!(
      Ecto.Changeset.change(video,
        embed_url: "/robots.txt",
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
  Measured: without the wait, about one suite run in three failed, each time in a different test.
  """
  def open(session, path) do
    session |> visit(path) |> connected()
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
  def signed_in(session, username) do
    account = Repo.insert!(User.changeset(%User{}, %{username: username}))

    token = Sessions.generate_session_token(account)
    options = Endpoint.session_options()

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, Endpoint.config(:secret_key_base))
      |> Plug.Session.call(Plug.Session.init(options))
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(Gate.session_key(), token)
      |> Plug.Conn.send_resp(200, "")

    # A cookie can only be set on a page of its host. `/robots.txt` is the smallest.
    session
    |> visit("/robots.txt")
    |> set_cookie(options[:key], conn.resp_cookies[options[:key]].value)

    account
  end

  @doc """
  Submits a setup code and leaves the browser on the claim form.

  Claiming an instance takes two forms: the setup code, then the name.
  Tests about later steps also submit the code, so the suite exercises the gate.

  The submit button is selected by form id, not label, because one test runs in German.

  The submit is a full page load to the same path, which `landed_on/2` cannot detect.
  So the function waits for `#claim-form`, which only the new document has, then for the socket.
  """
  def code_entered(session) do
    {:ok, code} = Instance.issue_code()

    session
    |> fill_in(Query.css("input[name=setup_code]"), with: code)
    |> click(Query.css("#setup-code-form button"))
    |> through_navigation(Query.css("#claim-form"))
    |> connected()
  end

  @doc """
  Waits until the browser's current path is `path` and returns the session.

  Use it after a ceremony, where the hook follows the handler's `%{redirect: …}` with a page load.
  Asserting on content during that load caused intermittent failures.
  Wallaby finds elements, then asks Chrome whether each is visible.
  If the document is replaced in between, Chrome returns
  *"Node with given id does not belong to the document"*.
  Wallaby's `execute_query/2` rescues `StaleReferenceError` and retries.
  This error arrives as a bare `RuntimeError` from the HTTP client and is not rescued.

  `current_path/1` holds no element references, so it is safe during the load.
  Once it matches, later queries find elements in the new document.
  It cannot detect a redirect to the current path. See `through_navigation/2`.
  """
  def landed_on(session, path) do
    result =
      retry(fn ->
        case current_path(session) do
          ^path -> {:ok, session}
          other -> {:error, {:still_at, other}}
        end
      end)

    case result do
      {:ok, session} -> session
      {:error, {:still_at, other}} -> flunk("never reached #{path}; still at #{other}")
    end
  end

  @doc """
  Runs `assert_has/2` and retries up to `attempts` times if the document was replaced meanwhile.

  Use it for a redirect to the current path, which `landed_on/2` cannot detect.
  There the path check passes before the navigation starts.
  Signing in is such a case: the handler returns `%{redirect: "/"}` from `/`.

  It detects the replacement afterwards instead of waiting for it.
  Matching Chrome's error message is fragile, so only this call site uses it.
  """
  def through_navigation(session, query, attempts \\ 10) do
    assert_has(session, query)
  rescue
    error in RuntimeError ->
      if Exception.message(error) =~ "does not belong to the document" and attempts > 0 do
        through_navigation(session, query, attempts - 1)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  @doc """
  Waits until the current page's LiveView is connected.

  For a page reached by a click instead of `open/2`.
  A full page load serves the document before the socket connects.
  A `phx-click` has no effect until the LiveView has joined.
  """
  def connected(session) do
    # `find/2` retries until the element appears and raises on timeout.
    find(session, Query.css("[data-phx-main].phx-connected"))

    session
  end

  @doc """
  Adds a virtual WebAuthn authenticator to this session's Chrome.

  Uses Chrome's own authenticator through chromedriver's CDP passthrough.
  Playwright's `credentials` API cannot serve this library.
  Its synthetic credential returns an empty `toJSON()`, which the library uses for serialization.
  No credential is seeded. Each test registers its own passkey, so registration is covered.
  """
  def virtual_authenticator(session) do
    command(session, "WebAuthn.enable", %{})

    %{"authenticatorId" => id} =
      command(session, "WebAuthn.addVirtualAuthenticator", %{
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

  @doc """
  Deletes all cookies of this browser session through WebDriver, which signs it out.

  `document.cookie` cannot do it. The session cookie is `HttpOnly` and hidden from JavaScript.
  Measured: `document.cookie` returns `""` on a signed-in page.
  A test that cleared cookies from JavaScript would stay signed in.
  """
  def clear_cookies(session) do
    {:ok, _} = Wallaby.HTTPClient.request(:delete, "#{session.url}/cookie")

    session
  end

  @doc "Returns every credential on the authenticator, to check whether a ceremony created one."
  def credentials(session, authenticator) do
    %{"credentials" => credentials} =
      command(session, "WebAuthn.getCredentials", %{authenticatorId: authenticator})

    credentials
  end

  @doc "Sets a deterministic first-visit language for a browser test."
  def language(session, locale) do
    command(session, "Network.enable", %{})
    command(session, "Network.setExtraHTTPHeaders", %{headers: %{"Accept-Language" => locale}})
    session
  end

  # chromedriver wraps the CDP result in a WebDriver envelope: `sessionId`, `status`, `value`.
  # The CDP result is in `value`.
  defp command(session, cmd, params) do
    {:ok, %{"value" => value}} =
      Wallaby.HTTPClient.request(:post, "#{session.url}/chromium/send_command_and_get_result", %{
        cmd: cmd,
        params: params
      })

    value
  end
end
