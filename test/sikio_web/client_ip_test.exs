# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ClientIpTest do
  @moduledoc """
  Client address resolution behind a reverse proxy.

  Rate limits count per client address. Behind Caddy every socket peer has the same address.
  Counting the peer gives all visitors one shared budget, so one client can lock out everyone.

  Any client can set the forwarding header. Trusting it from any peer lets a client choose its
  own budget.
  """
  # async: false, because several tests set trusted proxies in application configuration.
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

  # A container proxy is trusted by its network range, because its address can change.
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

  # The IPv4-mapped form a dual-stack socket reports for an IPv4 peer.
  # Production binds `::`, so Caddy on the same host arrives in this form. Measured, not assumed.
  @mapped_loopback {0, 0, 0, 0, 0, 65_535, 32_512, 1}

  # Clients control the header bytes. `to_charlist/1` raises `UnicodeConversionError` on invalid
  # UTF-8. This plug runs before every route, so a raise would fail the whole request.
  # The invalid entry is skipped and the valid entry before it is used.
  test "a forwarded header with invalid UTF-8 uses its last valid entry" do
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

  # Visitors behind one proxy resolve to distinct addresses, so their budgets stay separate.
  test "two visitors behind one proxy are told apart" do
    first = asked({127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.7"}])
    second = asked({127, 0, 0, 1}, [{"x-forwarded-for", "198.51.100.4"}])

    refute first == second
  end

  # The header is ignored from an untrusted peer.
  # Otherwise a directly connected client could claim a new address per attempt.
  test "a stranger speaking for somebody else is not believed" do
    assert asked({203, 0, 113, 9}, [{"x-forwarded-for", "198.51.100.4"}]) == {203, 0, 113, 9}
  end

  # Caddy writes `X-Forwarded-For` and passes other headers unchanged, so they are client input.
  # `RemoteIp` reads four headers by default, and the last one wins.
  # A client could then send `X-Real-IP` and choose its own budget.
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

  # Matching only the plain loopback would disable the plug on the production deployment.
  # Tests built on `Plug.Test.conn/3` use the plain form and would not catch it.
  test "a proxy that reached a dual-stack socket is still the loopback" do
    assert asked(@mapped_loopback, @forwarded) == {203, 0, 113, 7}
  end

  test "an address in its mapped form is counted as the address it is" do
    assert asked(@mapped_loopback, []) == {127, 0, 0, 1}
  end

  # On a home network or over WireGuard, visitors have private addresses.
  # `RemoteIp` treats those as reserved and returns none. The network would share one budget.
  test "visitors on a private network are told apart" do
    first = asked({127, 0, 0, 1}, [{"x-forwarded-for", "192.168.1.50"}])
    second = asked({127, 0, 0, 1}, [{"x-forwarded-for", "192.168.1.51"}])

    assert first == {192, 168, 1, 50}
    refute first == second
  end

  # An edge proxy forwards to a trusted internal proxy at a private address.
  # Taking the internal proxy for the visitor would give everyone behind it one budget.
  test "a proxy of our own inside the chain is not the visitor" do
    trusting([{10, 0, 0, 2}])

    forwarded = [{"x-forwarded-for", "203.0.113.7, 10.0.0.2"}]

    assert asked({10, 0, 0, 2}, forwarded) == {203, 0, 113, 7}
  end

  # An edge proxy and an internal proxy, both trusted.
  # The right-to-left walk skips both to reach the visitor.
  test "a chain of our own proxies is walked past, not stopped at" do
    trusting([{10, 0, 0, 1}, {10, 0, 0, 2}])

    forwarded = [{"x-forwarded-for", "203.0.113.7, 10.0.0.1"}]

    assert asked({10, 0, 0, 2}, forwarded) == {203, 0, 113, 7}
  end

  # The chain holds only loopback and trusted addresses, as in a proxy health check.
  # Without a visitor entry, the peer address is kept.
  test "a chain holding nobody but us leaves the peer standing" do
    trusting([{10, 0, 0, 1}, {10, 0, 0, 2}])

    forwarded = [{"x-forwarded-for", "127.0.0.1, 10.0.0.1"}]

    assert asked({10, 0, 0, 2}, forwarded) == {10, 0, 0, 2}
  end

  # One loopback address per backend is a common setup.
  # The documentation states that a same-host proxy needs no configuration.
  test "a proxy on another loopback address is still the loopback" do
    assert asked({127, 0, 0, 2}, @forwarded) == {203, 0, 113, 7}
  end

  test "a request with no header keeps the address it came from" do
    assert asked({127, 0, 0, 1}, []) == {127, 0, 0, 1}
  end

  test "a header nobody can read leaves the address alone" do
    assert asked({127, 0, 0, 1}, [{"x-forwarded-for", "not-an-address"}]) == {127, 0, 0, 1}
  end

  # Caddy appends to a client-supplied `X-Forwarded-For`.
  # The rightmost entry is the address Caddy saw.
  test "an invented entry ahead of the real one does not win" do
    forged = [{"x-forwarded-for", "198.51.100.4, 203.0.113.7"}]

    assert asked({127, 0, 0, 1}, forged) == {203, 0, 113, 7}
  end
end

defmodule SikioWeb.ClientIpBucketTest do
  @moduledoc """
  Rate-limit bucket keys for client addresses.

  An IPv6 client usually holds a whole `/64` and can rotate the lower 64 bits freely.
  The forwarding header is client-controlled, so an IPv6 bucket is the `/64` allocation.
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
