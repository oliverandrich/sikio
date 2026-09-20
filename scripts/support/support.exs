# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ReleaseSmoke.Support do
  @moduledoc "Small standard-library helpers for standalone operational scripts."

  defmodule CommandError do
    defexception message: "External command failed; inspect configuration and service logs."
  end

  def token(bytes \\ 12), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  def temporary(fun) do
    path = Path.join(System.tmp_dir!(), "sikio-ops-" <> token())
    File.mkdir!(path)
    File.chmod!(path, 0o700)

    try do
      fun.(path)
    after
      File.rm_rf!(path)
    end
  end

  def run([command | args], env, options \\ []) do
    temporary(fn directory ->
      error = Path.join(directory, "stderr")
      opts = [env: Enum.to_list(env)] ++ Keyword.take(options, [:cd])

      opts =
        if options[:stdout],
          do: Keyword.put(opts, :into, File.stream!(options[:stdout], [:write, :binary])),
          else: opts

      {output, status} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s(error=$1; shift; exec "$@" 2>"$error"),
            "sikio-command",
            error,
            command | args
          ],
          opts
        )

      if status != 0, do: raise(CommandError)
      if options[:stdout], do: "", else: output
    end)
  end
end
