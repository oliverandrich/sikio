# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.StarterDriftTest do
  @moduledoc """
  Whether this application's copies of generated files still say what the starter's do.

  Ithibati Starter writes the auth half of an application, so each of these files exists three
  times: here, in Chapisho, and in the template every new project is made from. Nothing kept them
  together and they drifted. Reading a forwarding header with `to_charlist/1` raises on bytes a
  visitor writes; both applications had it, the template had the fix *and* a test for it, and it
  stayed that way until somebody diffed the three by hand.

  Prose is ignored on purpose. Moduledocs are reworded and reflowed per application — a paragraph
  about "this blog" does not belong here — while a differing expression is what nobody meant.

  The comparison is against the *locked* starter, so a push to that repository does not turn this
  red on its own. Reconciling is `mix deps.update ithibati_starter`, which is a deliberate act
  and the moment to read what changed.
  """
  use ExUnit.Case, async: true

  alias Sikio.StarterDrift

  @app "sikio"

  # What this application promises to keep in step. Everything else the starter generates is
  # either ours by now or was never shared; the second test below is what stops that set from
  # growing by accident.
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

  # A file that quietly becomes identical is a file somebody should decide about: either it is
  # shared and belongs above, or it matches by chance and will drift again unwatched.
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

  # `code/2` drops a heredoc after `@moduledoc`/`@doc`, and every LiveView here carries an `~H`
  # one that it must not touch: eating a render function would make two different pages compare
  # equal, which is the shape of an assertion that cannot fail.
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
