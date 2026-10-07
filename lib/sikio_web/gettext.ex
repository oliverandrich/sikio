# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Gettext do
  @moduledoc """
  The Gettext backend. It compiles the translations under `priv/gettext`.

  Modules use it with `use Gettext` and the `:backend` option:

      use Gettext, backend: SikioWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.
  """
  use Gettext.Backend, otp_app: :sikio
end
