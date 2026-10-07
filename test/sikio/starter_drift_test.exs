# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.StarterDriftTest do
  @moduledoc """
  Compares this application's copies of generated files with the Ithibati Starter templates.

  Ithibati Starter generates the auth code. Each shared file exists in Sikio, in Chapisho and in
  the starter. The copies have diverged before. Both applications parsed a forwarding header with
  `to_charlist/1`, which raises on some client bytes. Only the template had the fix and its test.

  Comments and docs are ignored, because each application rewords them. Code must match.

  The comparison uses the locked starter version, so upstream pushes do not fail this test.
  `mix deps.update ithibati_starter` updates the lock; review the changes then.
  """
  use ExUnit.Case, async: true

  alias Sikio.StarterDrift

  @app "sikio"

  # Files kept identical to the starter. Other generated files are application-owned.
  # The second test fails when an unlisted file matches its template.
  @shared [
    "lib/__APP__/accounts/invitation.ex.tpl",
    "lib/__APP__/accounts/user.ex.tpl",
    "lib/__APP__/auth_cleanup.ex.tpl",
    "lib/__APP__/invitations.ex.tpl",
    "lib/__APP___web/client_ip.ex.tpl",
    "lib/__APP___web/controllers/session_controller.ex.tpl",
    "lib/__APP___web/controllers/session_html.ex.tpl",
    "lib/__APP___web/invitation_mail.ex.tpl",
    "lib/mix/tasks/auth.cleanup.ex.tpl",
    "priv/gettext/de/LC_MESSAGES/errors.po.tpl",
    "priv/repo/migrations/20260913120000_create_users.exs.tpl",
    "priv/repo/migrations/20260913120100_add_ithibati.exs.tpl",
    "priv/repo/migrations/20260918000000_add_challenges.exs.tpl",
    "test/support/browser_driver.ex.tpl"
  ]

  setup_all do
    root =
      StarterDrift.templates() ||
        flunk("""
        deps/ithibati_starter is not checked out, so this check cannot run.

        It is `only: [:dev, :test]` in mix.exs for exactly this reason. A skip here would be
        worse than no check at all: it would pass and mean nothing.
        """)

    {:ok, root: root, pairs: StarterDrift.pairs(root, @app)}
  end

  test "the files this application keeps in step with the starter still are", ctx do
    for template <- @shared do
      local = Enum.find_value(ctx.pairs, fn {t, l} -> t == template && l end)

      assert local,
             "#{template} is named as shared and has no counterpart here — was it renamed?"

      theirs = StarterDrift.code(Path.join(ctx.root, template), @app)
      ours = StarterDrift.code(local, @app)

      assert ours == theirs, """
      #{local} has drifted from #{template}.

      Only here:      #{inspect(ours -- theirs, limit: 5)}
      Only in theirs: #{inspect(theirs -- ours, limit: 5)}

      Whichever is right, both copies want it — and Chapisho has a third.
      """
    end
  end

  # An unlisted matching file needs a decision. Either it belongs in `@shared`, or the match is
  # coincidental and one copy should change.
  test "and nothing else has quietly become identical", ctx do
    undeclared =
      for {template, local} <- ctx.pairs,
          template not in @shared,
          StarterDrift.code(Path.join(ctx.root, template), @app) == StarterDrift.code(local, @app),
          do: template

    assert undeclared == [], """
    These match the starter's templates and are not named as shared:

    #{Enum.map_join(undeclared, "\n", &("  " <> &1))}

    Add them to @shared if they are meant to stay in step, or change one of the two if the
    match is a coincidence.
    """
  end

  # `code/2` drops heredocs after `@moduledoc` and `@doc` but must keep `~H` heredocs.
  # Dropping a render function would make two different templates compare equal.
  test "prose is dropped and markup is not", ctx do
    path = Path.join(System.tmp_dir!(), "drift_#{System.unique_integer([:positive])}.ex")

    File.write!(path, """
    defmodule Sikio.Sample do
      @moduledoc \"\"\"
      A paragraph nobody compares.
      \"\"\"

      # A comment nobody compares either.
      def render(assigns) do
        ~H\"\"\"
        <p>markup that counts</p>
        \"\"\"
      end
    end
    """)

    on_exit(fn -> File.rm(path) end)

    kept = StarterDrift.code(path, ctx[:app] || @app)

    assert "<p>markup that counts</p>" in kept
    refute "A paragraph nobody compares." in kept
    refute Enum.any?(kept, &String.starts_with?(&1, "#"))
  end
end
