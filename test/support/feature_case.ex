# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.FeatureCase do
  @moduledoc """
  A real browser, driving the real pages — and with them `priv/static/ithibati.js`, the half of
  Ithibati that runs on somebody else's machine.

  These are not `Phoenix.LiveViewTest` tests and cannot be: a passkey ceremony is
  `navigator.credentials`, a `fetch` that sets a cookie, and a redirect the hook follows. None of
  that exists without a browser.

  Wallaby shares the test's sandboxed connection with the server, so a test may look in the
  database at what the browser just did — which is how these assert that a ceremony *arrived*
  rather than only that a page changed.
  """
  use ExUnit.CaseTemplate

  # The test modules get this through the `using` block below; this module needs it too, because
  # `assert_has/2` is a macro that expands into `execute_query/2` and both have to be in scope here.
  import Wallaby.Browser

  alias Ithibati.Identity.Instance
  alias Wallaby.Query

  using do
    quote do
      use Wallaby.Feature

      setup %{session: session} do
        SikioWeb.FeatureCase.language(session, "en")
        SikioWeb.FeatureCase.room_for_the_suites_own_codes()
        :ok
      end

      import SikioWeb.FeatureCase
      import Wallaby.Query

      alias Sikio.Accounts.User
      alias Sikio.Repo
    end
  end

  @doc """
  Waits until nothing on the page matches `query`, and passes at once when nothing does.

  Wallaby's `refute_has/2` retries until the element appears, so it waits the whole
  `max_wait_time` on a page without it, and fails at once on a page that has not yet removed it.
  Where something must not appear after an action, assert first what the action does show.
  """
  def gone(session, query), do: Wallaby.Browser.assert_has(session, Wallaby.Query.count(query, 0))

  @doc "An item's address in the list of all items, as the library itself spells it."
  def item_path(entry), do: SikioWeb.ConnCase.item_path(entry)

  @doc """
  Goes to a page and waits until its LiveView has actually connected.

  Use this rather than `visit/2` for anything these tests then interact with. A page answers long
  before its socket does, and until it does, `phx-submit` is not wired and the mount patch has not
  run — so a click goes nowhere, and a `data-` attribute spoiled beforehand is quietly put back to
  what the template says. Measured: without the wait the suite failed about one run in three, on a
  different test each time, which reads as flakiness rather than as the race it is.
  """
  def open(session, path) do
    session |> visit(path) |> connected()
  end

  @doc """
  Raises the setup budget for the length of one browser test.

  Every test here that makes an account spends a code at the real endpoint, and a browser cannot
  be given an address of its own, so they all arrive on the loopback and share one counter. The
  shipped budget of ten a minute would then refuse the suite rather than a guesser. Nearly every
  feature signs up, and the suite does that faster than a hundred a minute.

  Only these tests need it. Everything else either writes the proof straight into the session or
  is the budget's own test, which sets a budget and an address of its own.
  """
  def room_for_the_suites_own_codes do
    Sikio.TestConfig.put_budget(:setup, {1000, 60})
    # Each sign-up is a passkey ceremony on the same loopback, so the same holds for those.
    Sikio.TestConfig.put_budget(:ceremony, {1000, 60})
  end

  @doc """
  Claims the instance as `username` with a virtual passkey and answers the account.

  Most browser tests begin with an account and are about what comes after. The ceremony is the
  real one, so a broken sign-up still fails them.
  """
  def signed_up(session, username) do
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> fill_in(Query.css("input[name=username]"), with: username)
    |> click(Query.button("Create your passkey"))
    |> landed_on("/recovery-codes")

    Sikio.Repo.get_by!(Sikio.Accounts.User, username: username)
  end

  @doc """
  Types the operator's code and leaves the browser on the form that asks for a name.

  Every instance protects its claim, so claiming one is two forms rather than one. A test that is
  really about what comes after the name still walks through this, which is what makes the gate
  something the suite drives rather than something it describes.

  The submit button is found by its form rather than by its label, because one of these tests
  runs the interface in German.

  Submitting is a full page load back to the same path, which is the swap `landed_on/2` cannot
  wait for. So the new document is waited for by the form only it has, and the socket is asked
  about afterwards, once there is one document to ask.
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
  Waits until the browser has actually arrived at a path, and answers the session.

  For the moment after a ceremony, where the hook follows the handler's `%{redirect: …}` with a
  full page load. Asserting on content across that swap is what produced the one failure this
  suite could not explain: Wallaby finds the elements, then asks Chrome whether each is visible,
  and if the document has been replaced in between Chrome answers *"Node with given id does not
  belong to the document"*. Wallaby's `execute_query/2` rescues `StaleReferenceError` and would
  have retried; this arrives as a bare `RuntimeError` from the HTTP client and escapes.

  `current_path/1` holds no element references, so it is safe to ask across the swap; once it
  answers, the document a later query finds is the new one. Where the redirect leads back to the
  page the browser is already on, this cannot help — see `through_navigation/1`.
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
  Runs an assertion, and runs it again if the document was swapped underneath it.

  For the redirect `landed_on/2` cannot wait for: one that leads to the path the browser is already
  on, where the poll is satisfied before the navigation has even started. Signing in is that —
  the handler answers `%{redirect: "/"}` from a page already at `/`.

  So this one does not predict the swap; it notices it happened. Matching on Chrome's message is
  narrow, which is why it is confined to the single site that cannot be solved by waiting.
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
  Waits where the browser already is, for a page it reached by clicking rather than by `open/2`.

  Same race, same reason: a full page load leaves a document that answers before its socket does,
  and a `phx-click` on it goes nowhere until the view has joined.
  """
  def connected(session) do
    # `find/2` blocks and raises if it never appears, which is the waiting and the check in one.
    find(session, Query.css("[data-phx-main].phx-connected"))

    session
  end

  @doc """
  Attaches a virtual authenticator to this session's browser.

  Chrome's own, reached through chromedriver's CDP passthrough. Wallaby's `browserContext`
  equivalent — Playwright's first-class `credentials` API — cannot serve this library: it hands the
  page a synthetic credential whose `toJSON()` comes back empty, and `toJSON()` is exactly what the
  library serialises with. Nothing is ever seeded: these tests register their own passkey, which is
  the property worth proving.
  """
  def virtual_authenticator(session) do
    command(session, "WebAuthn.enable", %{})

    %{"authenticatorId" => id} =
      command(session, "WebAuthn.addVirtualAuthenticator", %{
        options: %{
          protocol: "ctap2",
          # A platform authenticator — Touch ID, Windows Hello — which is what a passkey for a web
          # application actually is.
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
  Throws away every cookie this browser holds, signing it out.

  Through WebDriver rather than `document.cookie`: the session cookie is `HttpOnly`, so JavaScript
  cannot see it, let alone expire it — measured, `document.cookie` answers `""` on a signed-in
  page. A test that cleared it that way would go on being signed in and would quietly stop
  exercising whatever it opened a fresh session to show.
  """
  def clear_cookies(session) do
    {:ok, _} = Wallaby.HTTPClient.request(:delete, "#{session.url}/cookie")

    session
  end

  @doc "Every credential the *page* registered, so a test can say whether a ceremony reached one."
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

  # chromedriver answers the WebDriver envelope — `sessionId`, `status`, `value` — and what CDP
  # returned is inside `value`.
  defp command(session, cmd, params) do
    {:ok, %{"value" => value}} =
      Wallaby.HTTPClient.request(:post, "#{session.url}/chromium/send_command_and_get_result", %{
        cmd: cmd,
        params: params
      })

    value
  end
end
