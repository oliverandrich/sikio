# SPDX-License-Identifier: AGPL-3.0-or-later

import Config

# AGPL section 13: a deployment that modified Sikio offers its own source, not this one. A
# wrong address is refused here rather than shown as a link that goes nowhere. See
# docs/operations.md for what an operator sets.
case "SOURCE_URL" |> System.get_env("") |> String.trim() do
  # How a compose file or an EnvironmentFile writes a variable it has no value for.
  "" ->
    :ok

  source_url ->
    case URI.parse(source_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ~w(http https) and is_binary(host) and host != "" ->
        config :sikio, :source_url, source_url

      _ ->
        raise """
        environment variable SOURCE_URL is not an absolute http or https URL: #{source_url}
        For example: https://github.com/you/sikio
        """
    end
end

# Which addresses may speak for somebody else. Behind a reverse proxy every request arrives from
# the same socket, so the address a budget is counted against comes from the proxy's header, and
# that header is only believed on a connection from here. The loopback is trusted already, which
# is where a proxy on the same host speaks from. See docs/operations.md.
case "TRUSTED_PROXIES" |> System.get_env("") |> String.trim() do
  "" ->
    :ok

  names ->
    config :sikio,
           :trusted_proxies,
           names
           |> String.split(",", trim: true)
           |> Enum.map(fn name ->
             name = String.trim(name)

             case :inet.parse_strict_address(to_charlist(name)) do
               {:ok, address} ->
                 address

               {:error, _reason} ->
                 raise """
                 environment variable TRUSTED_PROXIES names something that is not an address: #{inspect(name)}
                 For example: TRUSTED_PROXIES=10.0.0.2,fd00::2
                 """
             end
           end)
end

# How often a feed is asked, in minutes. The scheduler looks every five minutes, so that is the
# shortest interval it can keep. See docs/operations.md.
case "FEED_POLL_MINUTES" |> System.get_env("") |> String.trim() do
  "" ->
    :ok

  minutes ->
    case Integer.parse(minutes) do
      {minutes, ""} when minutes >= 5 ->
        config :sikio, :feed_poll_minutes, minutes

      _ ->
        raise """
        environment variable FEED_POLL_MINUTES is not a whole number of at least 5 minutes: #{inspect(minutes)}
        For example: FEED_POLL_MINUTES=60
        """
    end
end

# Mail is opt-in and an instance that addresses its accounts requires it, which `Sikio.Identity`
# checks where the instance starts. Enabling it here means a working SMTP submission
# configuration: a missing value stops the boot rather than failing at the first invitation.
if config_env() != :test and System.get_env("MAIL_ENABLED") == "true" do
  smtp_host = System.fetch_env!("SMTP_HOST")

  config :sikio, :mail_enabled, true
  config :sikio, :mail_from, {"Sikio", System.fetch_env!("MAIL_FROM")}

  smtp_port = String.to_integer(System.get_env("SMTP_PORT", "587"))

  config :sikio, Sikio.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_host,
    port: smtp_port,
    username: System.fetch_env!("SMTP_USERNAME"),
    password: System.fetch_env!("SMTP_PASSWORD"),
    auth: :always,
    # 465 is implicit TLS and 587 is STARTTLS. Hardcoding either one against a port the operator
    # sets means a client speaking the wrong thing, and finding out at the first invitation.
    tls: if(smtp_port == 465, do: :never, else: :always),
    ssl: smtp_port == 465,
    retries: 0,
    tls_options: [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_host),
      depth: 99,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
end

# An account is named or addressed. Addressing them requires the mail configuration above, and
# `Sikio.Identity` refuses to start an instance that asks for one without the other.
#
# Not in tests, where a shell that happens to export this would otherwise decide what the suite
# runs against.
if config_env() != :test do
  case "ACCOUNT_IDENTITY" |> System.get_env("") |> String.trim() do
    "" ->
      :ok

    "username" ->
      config :sikio, :account_identity, :username

    "email" ->
      config :sikio, :account_identity, :email

    other ->
      raise """
      environment variable ACCOUNT_IDENTITY is neither: #{inspect(other)}

      An account is named or addressed, so this is "username" or "email".
      """
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/sikio start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :sikio, SikioWeb.Endpoint, server: true
end

config :sikio, SikioWeb.Endpoint,
  http: [
    port:
      String.to_integer(
        System.get_env("PORT", if(config_env() == :test, do: "4102", else: "4000"))
      )
  ]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :sikio, SikioWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/sikio_web/router\.ex$"E,
        ~r"lib/sikio_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # A release brings its schema up to date as it starts. An operator who migrates by hand, with
  # bin/migrate, turns that off. Development data is never migrated by starting a server.
  migrate_on_start =
    case "SIKIO_MIGRATE_ON_START" |> System.get_env("") |> String.trim() do
      value when value in ["", "true"] ->
        true

      "false" ->
        false

      other ->
        raise """
        environment variable SIKIO_MIGRATE_ON_START is neither true nor false: #{inspect(other)}
        """
    end

  config :sikio, :migrate_on_start, migrate_on_start

  # Pictures fetched from publishers are written here. It lies outside the release, so an upgrade
  # replaces the release without throwing the cache away.
  picture_cache_dir =
    case System.get_env("PICTURE_CACHE_DIR", "") |> String.trim() do
      "/" <> _ = path ->
        path

      _ ->
        raise """
        environment variable PICTURE_CACHE_DIR is missing or not an absolute path.
        For example: /var/lib/sikio/pictures
        """
    end

  config :sikio, picture_cache_dir: picture_cache_dir

  # One release serves both databases. SIKIO_DATABASE chooses one, SQLite unless it says
  # otherwise, and the choice decides the variable that names it. A SQLite file is application
  # data and lives outside the release, like the picture cache.
  database =
    case System.get_env("SIKIO_DATABASE", "sqlite") do
      "sqlite" -> :sqlite
      "postgres" -> :postgres
      other -> raise "SIKIO_DATABASE must be sqlite or postgres, not #{inspect(other)}"
    end

  config :sikio, :database, database

  if database == :sqlite do
    database_path =
      case System.get_env("DATABASE_PATH", "") |> String.trim() do
        "/" <> _ = path ->
          path

        _ ->
          raise """
          environment variable DATABASE_PATH is missing or not an absolute path.
          For example: /var/lib/sikio/sikio.db
          """
      end

    config :sikio, Sikio.Repo,
      database: database_path,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
  else
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :sikio, Sikio.Repo,
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      # For machines with several cores, consider starting multiple pools of `pool_size`
      # pool_count: 4,
      socket_options: maybe_ipv6
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # force_ssl redirects plain http to this host, so a default would send visitors elsewhere.
  host =
    case "PHX_HOST" |> System.get_env("") |> String.trim() do
      "" ->
        raise """
        environment variable PHX_HOST is missing.
        For example: sikio.example.org
        """

      host ->
        host
    end

  # Every interface unless told otherwise. A proxy on the same host can narrow it to loopback.
  bind_ip =
    case "PHX_BIND_IP" |> System.get_env("") |> String.trim() do
      "" ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      address ->
        case :inet.parse_strict_address(to_charlist(address)) do
          {:ok, ip} ->
            ip

          {:error, _reason} ->
            raise """
            environment variable PHX_BIND_IP is not an address: #{inspect(address)}
            For example: PHX_BIND_IP=127.0.0.1
            """
        end
    end

  config :sikio, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :sikio, SikioWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: bind_ip],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :sikio, SikioWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :sikio, SikioWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
