# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.RuntimeConfigTest do
  @moduledoc """
  Tests how `config/runtime.exs` reads environment variables, using `Config.Reader.read!/2`.

  No other test executes most of this file. A release reads it once at boot.
  A mishandled value shows up as a failed boot, or as a running instance with the wrong setting.
  """
  use ExUnit.Case, async: false

  # The variables a production boot requires. Each test overrides the ones it checks.
  @prod %{
    "DATABASE_URL" => "ecto://sikio:secret@localhost/sikio",
    "DATABASE_PATH" => "/var/lib/sikio/sikio.db",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "PHX_HOST" => "sikio.example",
    "PICTURE_CACHE_DIR" => "/var/lib/sikio/pictures",
    "PHX_BIND_IP" => nil
  }

  # Sets each variable, or deletes it for nil. `on_exit` restores the previous values.
  defp read(mix_env, env) do
    previous = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)
    on_exit(fn -> put_env(previous) end)
    put_env(env)
    Config.Reader.read!("config/runtime.exs", env: mix_env)
  end

  defp put_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp prod(env \\ %{}), do: read(:prod, Map.merge(@prod, env))
  defp sikio(config, key), do: get_in(config, [:sikio, key])
  defp endpoint(config), do: get_in(config, [:sikio, SikioWeb.Endpoint])

  describe "SIKIO_MIGRATE_ON_START" do
    defp migrates(value),
      do: %{"SIKIO_MIGRATE_ON_START" => value} |> prod() |> sikio(:migrate_on_start)

    # A release migrates on start unless the operator disables it to migrate manually.
    test "a release migrates on start unless told not to" do
      assert migrates(nil) == true
      assert migrates("") == true
      assert migrates("true") == true
      assert migrates("false") == false
    end

    test "anything but true or false stops the boot" do
      assert_raise RuntimeError, ~r/SIKIO_MIGRATE_ON_START/, fn -> migrates("no") end
    end

    # Development databases are migrated explicitly, never on server start.
    test "development and tests never migrate on start" do
      for env <- [:dev, :test] do
        config = read(env, %{"SIKIO_MIGRATE_ON_START" => "true"})
        assert sikio(config, :migrate_on_start) == nil
      end
    end
  end

  describe "FEED_POLL_MINUTES" do
    defp interval(value),
      do: :test |> read(%{"FEED_POLL_MINUTES" => value}) |> sikio(:feed_poll_minutes)

    test "a number of minutes sets how often a feed is asked" do
      assert interval("90") == 90
    end

    test "an unset variable leaves the default alone" do
      assert interval("") == nil
    end

    # The scheduler runs every five minutes, so a shorter interval cannot take effect.
    test "anything but a whole number of at least five minutes stops the boot" do
      for value <- ["abc", "0", "4", "1.5", "-60"] do
        assert_raise RuntimeError, ~r/FEED_POLL_MINUTES/, fn -> interval(value) end
      end
    end
  end

  describe "TRUSTED_PROXIES" do
    defp configured(value),
      do: :test |> read(%{"TRUSTED_PROXIES" => value}) |> sikio(:trusted_proxies)

    test "addresses arrive as addresses, in both families" do
      assert configured("10.0.0.2, fd00::2") == [{10, 0, 0, 2}, {64_768, 0, 0, 0, 0, 0, 0, 2}]
    end

    # A recreated container proxy gets a new address. A CIDR range covers its network.
    # It is parsed into the base address and the prefix length.
    test "a range arrives as its address and the bits it keeps, in both families" do
      assert configured("172.20.0.0/16, fd00::/64") ==
               [{{172, 20, 0, 0}, 16}, {{64_768, 0, 0, 0, 0, 0, 0, 0}, 64}]
    end

    test "a range its family cannot hold stops the boot and says which one" do
      assert_raise RuntimeError, ~r{10\.0\.0\.0/33}, fn -> configured("10.0.0.0/33") end
      assert_raise RuntimeError, ~r{fd00::/129}, fn -> configured("fd00::/129") end
      assert_raise RuntimeError, ~r{10\.0\.0\.0/x}, fn -> configured("10.0.0.0/x") end
    end

    # systemd units and env files write an unset variable as an empty string.
    # It means unset, not a list with one empty entry.
    test "an unset variable leaves the default alone" do
      assert configured("") == nil
    end

    # A stray comma produces an empty entry. The error message shows it as `""`, not as a blank.
    test "an entry of nothing says so rather than pointing at a blank" do
      assert_raise RuntimeError, ~r/""/, fn -> configured("10.0.0.2, ,fd00::2") end
    end

    # A hostname raises at boot. Dropping it silently would trust one proxy fewer than configured.
    # The rate limit would then count the proxy address instead of the client.
    test "something that is not an address stops the boot and says which one" do
      assert_raise RuntimeError, ~r/proxy\.example\.com/, fn ->
        configured("10.0.0.2,proxy.example.com")
      end
    end
  end

  # `runtime.exs` skips this block in `:test`, so an exported shell variable cannot affect the
  # suite. These tests read it as `:dev`.
  describe "ACCOUNT_IDENTITY" do
    defp identity(value),
      do: :dev |> read(%{"ACCOUNT_IDENTITY" => value}) |> sikio(:account_identity)

    test "an account is named or addressed, and says so either way" do
      assert identity("email") == :email
      assert identity("username") == :username
    end

    # Same rule as `TRUSTED_PROXIES`: invalid values raise instead of being ignored.
    # Ignoring `Email` would boot with usernames although the operator chose email addresses.
    test "anything else stops the boot rather than being dropped quietly" do
      assert_raise RuntimeError, ~r/Email/, fn -> identity("Email") end
    end
  end

  describe "SOURCE_URL" do
    defp source(value), do: :test |> read(%{"SOURCE_URL" => value}) |> sikio(:source_url)

    test "an absolute address is what the footer offers" do
      assert source("https://git.example.org/sikio") == "https://git.example.org/sikio"
    end

    # A URL without a scheme would render as a relative path on this instance.
    test "anything else stops the boot" do
      assert_raise RuntimeError, ~r/SOURCE_URL/, fn -> source("git.example.org/sikio") end
    end
  end

  describe "mail" do
    @smtp %{
      "MAIL_ENABLED" => "true",
      "MAIL_FROM" => "sikio@example.org",
      "SMTP_HOST" => "smtp.example.org",
      "SMTP_USERNAME" => "sikio",
      "SMTP_PASSWORD" => "secret",
      "SMTP_PORT" => nil
    }

    defp mailer(env), do: :dev |> read(Map.merge(@smtp, env)) |> sikio(Sikio.Mailer)

    test "the submission port speaks STARTTLS" do
      assert %{port: 587, tls: :always, ssl: false} = Map.new(mailer(%{}))
    end

    test "port 465 speaks TLS from the first byte" do
      assert %{port: 465, tls: :never, ssl: true} = Map.new(mailer(%{"SMTP_PORT" => "465"}))
    end

    # Failing at boot surfaces a missing setting before the first invitation mail fails.
    test "a missing setting stops the boot" do
      assert_raise System.EnvError, ~r/SMTP_PASSWORD/, fn -> mailer(%{"SMTP_PASSWORD" => nil}) end
    end
  end

  describe "production" do
    test "listens on every interface unless told otherwise" do
      assert endpoint(prod())[:http][:ip] == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    # With Caddy on the same host, the HTTP port can bind to loopback only.
    test "PHX_BIND_IP narrows where it listens, in both families" do
      assert endpoint(prod(%{"PHX_BIND_IP" => "127.0.0.1"}))[:http][:ip] == {127, 0, 0, 1}
      assert endpoint(prod(%{"PHX_BIND_IP" => "::1"}))[:http][:ip] == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "PHX_BIND_IP that is not an address stops the boot" do
      assert_raise RuntimeError, ~r/PHX_BIND_IP/, fn -> prod(%{"PHX_BIND_IP" => "localhost"}) end
    end

    test "PHX_HOST names the public address" do
      assert endpoint(prod())[:url][:host] == "sikio.example"
    end

    # `force_ssl` redirects to this host. A wrong default would redirect HTTP requests elsewhere.
    test "a missing PHX_HOST stops the boot" do
      assert_raise RuntimeError, ~r/PHX_HOST/, fn -> prod(%{"PHX_HOST" => nil}) end
      assert_raise RuntimeError, ~r/PHX_HOST/, fn -> prod(%{"PHX_HOST" => " "}) end
    end

    test "a relative PICTURE_CACHE_DIR stops the boot" do
      assert_raise RuntimeError, ~r/PICTURE_CACHE_DIR/, fn ->
        prod(%{"PICTURE_CACHE_DIR" => "pictures"})
      end
    end
  end

  # `SIKIO_DATABASE` decides which variable is required. These tests follow the suite's database.
  describe "the database" do
    if Application.compile_env!(:sikio, :database) == :sqlite do
      test "DATABASE_PATH names the SQLite file" do
        assert get_in(prod(), [:sikio, Sikio.Repo, :database]) == "/var/lib/sikio/sikio.db"
      end

      test "a missing or relative DATABASE_PATH stops the boot" do
        for path <- [nil, "sikio.db"] do
          assert_raise RuntimeError, ~r/DATABASE_PATH/, fn -> prod(%{"DATABASE_PATH" => path}) end
        end
      end
    else
      test "DATABASE_URL names the Postgres database" do
        assert get_in(prod(), [:sikio, Sikio.Repo, :url]) == "ecto://sikio:secret@localhost/sikio"
      end

      test "a missing DATABASE_URL stops the boot" do
        assert_raise RuntimeError, ~r/DATABASE_URL/, fn -> prod(%{"DATABASE_URL" => nil}) end
      end
    end
  end
end
