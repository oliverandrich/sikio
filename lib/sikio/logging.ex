# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Logging do
  @moduledoc """
  What production writes to its log: one JSON object per line on stdout, at `LOG_LEVEL`.

  Only the metadata named here reaches a line. Messages and `reason` are not filtered, so callers
  keep names, codes and tokens out of them. See docs/operations.md.
  """

  alias LoggerJSON.Formatters.Basic

  require Logger

  # Which feed, account or job a line concerns, why something failed, and Phoenix's request id.
  # config/config.exs repeats this list for the plain lines of development and tests.
  @metadata [
    :request_id,
    :feed_id,
    :feed_title,
    :host,
    :account_id,
    :reason,
    :worker,
    :job_id,
    :attempt
  ]

  # Not debug: it turns on LiveView's and Ecto's own lines, with sessions and query parameters.
  @levels ~w(emergency alert critical error warning notice info)

  # A reason is cut to this length, so a term a job returns cannot carry much into a line.
  @reason_length 200

  @doc "The formatter production logs with."
  def formatter, do: Basic.new(metadata: @metadata)

  @doc """
  Drops the connection a crashed request is logged with. The formatter would write its path, which
  may hold an invitation's token, and the visitor's address and agent.
  """
  def drop_request(%{meta: meta} = event, _config), do: %{event | meta: Map.delete(meta, :conn)}

  @doc "Logs every job that fails, with its worker, id, attempt and why. Called once at start."
  def attach_job_failures do
    :telemetry.detach("sikio-job-failures")

    :telemetry.attach(
      "sikio-job-failures",
      [:oban, :job, :exception],
      &__MODULE__.job_failed/4,
      nil
    )
  end

  # A feed refresh logs its own failure, with the feed it concerns.
  @doc false
  def job_failed(_event, _measurements, %{job: %{worker: "Sikio.Feeds.Refresh"}}, _config),
    do: :ok

  # telemetry detaches a handler that raises, so nothing here may.
  def job_failed(_event, _measurements, %{job: job} = meta, _config) do
    Logger.warning("job failed",
      worker: job.worker,
      job_id: job.id,
      attempt: job.attempt,
      reason: reason(meta)
    )
  rescue
    _ -> :ok
  end

  defp reason(%{kind: kind, error: error}) do
    text =
      if is_exception(error),
        do: Exception.message(error),
        else: Exception.format_banner(kind, error)

    String.slice(text, 0, @reason_length)
  end

  defp reason(_meta), do: "unknown"

  @doc "The level `LOG_LEVEL` names, in any case, info when it names none. Any other is refused."
  def level(nil), do: :info

  def level(value) do
    case value |> String.trim() |> String.downcase() do
      "" ->
        :info

      level when level in @levels ->
        String.to_existing_atom(level)

      _ ->
        raise ArgumentError,
              "LOG_LEVEL must be one of #{Enum.join(@levels, ", ")}, not #{inspect(value)}"
    end
  end
end
