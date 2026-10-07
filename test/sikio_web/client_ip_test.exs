# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ClientIpTest do
  @moduledoc """
  Who a request is counted against, when a proxy stands in front.

  Every budget in this application is spent per address, so the address decides who a refusal
  refuses. Behind Caddy the socket always comes from the same place, and counting that would give
  every visitor one shared budget: one stranger could spend it and lock out everybody else.

  The header that carries the real address is written by whoever sends it, so believing it
  without asking where it came from is the opposite mistake. Then a visitor picks their own
  budget and the limit means nothing at all.
  """
  # Not `async: true`: two of these name a trusted proxy, which is application configuration.
  use ExUnit.Case, async: false

  alias SikioWeb.ClientIp

  defp trusting(addresses), do: Sikio.TestConfig.put_env(:sikio, :trusted_proxies, addresses)

  defp asked(peer, headers) do
    :get
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, peer)
    |> Map.put(:req_headers, headers)
    |> ClientIp.call(ClientIp.init([]))
    |> Map.fetch!(:remote_ip)
  end

  @forwarded [{"x-forwarded-for", "203.0.113.7"}]

  # A proxy in a container is trusted by the network it lives on, whatever address it has today.
  test "a proxy anywhere in a trusted range speaks for the visitor it forwarded" do
    trusting([{{172, 20, 0, 0}, 16}, {{64_768, 0, 0, 0, 0, 0, 0, 0}, 64}])

    assert asked({172, 20, 3, 4}, @forwarded) == {203, 0, 113, 7}
    assert asked({64_768, 0, 0, 0, 1, 2, 3, 4}, @forwarded) == {203, 0, 113, 7}
  end

  test "an address outside every trusted range is not believed" do
    trusting([{{172, 20, 0, 0}, 16}, {{64_768, 0, 0, 0, 0, 0, 0, 0}, 64}])

    assert asked({172, 21, 0, 1}, @forwarded) == {172, 21, 0, 1}
    assert asked({64_768, 0, 0, 1, 0, 0, 0, 1}, @forwarded) == {64_768, 0, 0, 1, 0, 0, 0, 1}
  end

  # What a dual-stack socket reports for a peer that connected over IPv4. Production binds `::`,
  # so this is the form Caddy on the same host actually arrives in. Measured, not guessed.
  @mapped_loopback {0, 0, 0, 0, 0, 65_535, 32_512, 1}

  # The header is written by whoever sends the request, so its bytes are a visitor's to choose.
  # `to_charlist/1` raises `UnicodeConversionError` on bytes that are not UTF-8, and this plug
  # runs in front of everything — the raise would be a request nobody could make succeed, from a
  # header nobody validates. The address is unreadable either way; what matters is that the
  # socket still answers for it.
  test "a forwarded header that is not UTF-8 falls back to the socket" do
    header = [{"x-forwarded-for", <<"203.0.113.7, ", 0xFF, 0xFE>>}]

    assert asked({127, 0, 0, 1}, header) == {203, 0, 113, 7}
  end

  test "and one that is only rubbish is answered by the socket" do
    header = [{"x-forwarded-for", <<0xFF, 0xFE>>}]

    assert asked({127, 0, 0, 1}, header) == {127, 0, 0, 1}
  end

  test "a proxy on the loopback speaks for the visitor it forwarded" do
    assert asked({127, 0, 0, 1}, @forwarded) == {203, 0, 113, 7}
  end

  # Two visitors behind one proxy are two addresses, which is the whole point: a budget spent by
  # one of them is not a budget the other has lost.
  test "two visitors behind one proxy are told apart" do
    first = asked({127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.7"}])
    second = asked({127, 0, 0, 1}, [{"x-forwarded-for", "198.51.100.4"}])

    refute first == second
  end

  # The header is a claim, and a claim is only worth the connection it arrived on. Exposed
  # directly, this is how somebody would buy themselves a fresh budget for every attempt.
  test "a stranger speaking for somebody else is not believed" do
    assert asked({203, 0, 113, 9}, [{"x-forwarded-for", "198.51.100.4"}]) == {203, 0, 113, 9}
  end

  # Caddy writes `X-Forwarded-For` and hands the rest of the request through untouched, so
  # anything else naming an address is the visitor's own word. `RemoteIp` reads four headers
  # unless told otherwise and the last one wins: a visitor sends `X-Real-IP` and picks their
  # own budget, which is the whole thing this plug exists to prevent.
  test "only the header the proxy writes is believed" do
    for {name, value} <- [
          {"x-real-ip", "9.9.9.9"},
          {"x-client-ip", "9.9.9.9"},
          {"forwarded", "for=9.9.9.9"}
        ] do
      headers = [{"x-forwarded-for", "203.0.113.7"}, {name, value}]

      assert asked({127, 0, 0, 1}, headers) == {203, 0, 113, 7}, name
    end
  end

  # Matching only the plain form would leave this plug doing nothing on exactly the deployment it
  # was written for, and no test built on `Plug.Test.conn/3` would ever notice.
  test "a proxy that reached a dual-stack socket is still the loopback" do
    assert asked(@mapped_loopback, @forwarded) == {203, 0, 113, 7}
  end

  test "an address in its mapped form is counted as the address it is" do
    assert asked(@mapped_loopback, []) == {127, 0, 0, 1}
  end

  # An instance on a home network, or reached over WireGuard, sees private visitor addresses.
  # `RemoteIp` calls those reserved and answers with nothing at all, which would put the whole
  # network back into one budget.
  test "visitors on a private network are told apart" do
    first = asked({127, 0, 0, 1}, [{"x-forwarded-for", "192.168.1.50"}])
    second = asked({127, 0, 0, 1}, [{"x-forwarded-for", "192.168.1.51"}])

    assert first == {192, 168, 1, 50}
    refute first == second
  end

  # An edge proxy, then one of ours on a private address. The inner one is ours, and mistaking it
  # for the visitor puts everybody behind it back into one budget.
  test "a proxy of our own inside the chain is not the visitor" do
    trusting([{10, 0, 0, 2}])

    forwarded = [{"x-forwarded-for", "203.0.113.7, 10.0.0.2"}]

    assert asked({10, 0, 0, 2}, forwarded) == {203, 0, 113, 7}
  end

  # Two of ours in front, which is what an edge proxy plus an internal one looks like. Walking
  # from the right has to pass both before it finds the visitor.
  test "a chain of our own proxies is walked past, not stopped at" do
    trusting([{10, 0, 0, 1}, {10, 0, 0, 2}])

    forwarded = [{"x-forwarded-for", "203.0.113.7, 10.0.0.1"}]

    assert asked({10, 0, 0, 2}, forwarded) == {203, 0, 113, 7}
  end

  # Nothing in the chain but our own machines: a health check from the proxy itself, or a probe
  # that never came from anybody. There is no visitor to find, so the peer stands.
  test "a chain holding nobody but us leaves the peer standing" do
    trusting([{10, 0, 0, 1}, {10, 0, 0, 2}])

    forwarded = [{"x-forwarded-for", "127.0.0.1, 10.0.0.1"}]

    assert asked({10, 0, 0, 2}, forwarded) == {10, 0, 0, 2}
  end

  # Giving each backend its own loopback address is an ordinary way to run several of them, and
  # the documentation promises a proxy on the same machine needs no configuration.
  test "a proxy on another loopback address is still the loopback" do
    assert asked({127, 0, 0, 2}, @forwarded) == {203, 0, 113, 7}
  end

  test "a request with no header keeps the address it came from" do
    assert asked({127, 0, 0, 1}, []) == {127, 0, 0, 1}
  end

  test "a header nobody can read leaves the address alone" do
    assert asked({127, 0, 0, 1}, [{"x-forwarded-for", "not-an-address"}]) == {127, 0, 0, 1}
  end

  # What Caddy actually sends when a visitor made the header up first: it appends rather than
  # replaces, so the rightmost entry is the one it saw itself.
  test "an invented entry ahead of the real one does not win" do
    forged = [{"x-forwarded-for", "198.51.100.4, 203.0.113.7"}]

    assert asked({127, 0, 0, 1}, forged) == {203, 0, 113, 7}
  end
end

defmodule SikioWeb.ClientIpBucketTest do
  @moduledoc """
  The address a budget is counted against, which is not always the address itself.

  A visitor with IPv6 usually holds a whole `/64` and can rotate the lower half for free. Before
  the forwarding header was believed, a proxy collapsed everybody onto one socket address and
  that was unreachable. Believing the header hands the key to whoever sends the request, so what
  is counted has to be the allocation rather than the address.
  """
  use ExUnit.Case, async: true

  alias SikioWeb.ClientIp

  test "one IPv6 allocation is one bucket, however the lower half moves" do
    assert ClientIp.bucket({0x2001, 0xDB8, 0, 1, 0, 0, 0, 1}) ==
             ClientIp.bucket({0x2001, 0xDB8, 0, 1, 0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD})
  end

  test "another allocation is another bucket" do
    refute ClientIp.bucket({0x2001, 0xDB8, 0, 1, 0, 0, 0, 1}) ==
             ClientIp.bucket({0x2001, 0xDB8, 0, 2, 0, 0, 0, 1})
  end

  test "an IPv4 address is one address and is counted as it is" do
    assert ClientIp.bucket({203, 0, 113, 7}) == {203, 0, 113, 7}
  end
end
