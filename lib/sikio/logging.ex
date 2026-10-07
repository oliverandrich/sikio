# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Logging do
  @moduledoc """
  Production logging: one JSON object per line on stdout, at `LOG_LEVEL`.

  Only the metadata named here reaches a line. Messages and `reason` are not filtered, so callers
  keep names, codes and tokens out of them. See docs/operations.md.
  """

  alias LoggerJSON.Formatters.Basic

  require Logger

  # The feed, account or job of a line, the failure reason, and Phoenix's request id.
  # config/config.exs repeats this list for the plain-text format in development and tests.
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

  # No debug: it enables LiveView and Ecto lines that include sessions and query parameters.
  @levels ~w(emergency alert critical error warning notice info)

  # Reasons are truncated to this length, which bounds how much of a job's error reaches a line.
  @reason_length 200

  @doc "Returns the production log formatter."
  def formatter, do: Basic.new(metadata: @metadata)

  @doc """
  Logger filter that removes `:conn` from event metadata, as attached to a crashed request.
  The formatter would log its path, which may hold an invitation token, and the client's address
  and user agent.
  """
  def drop_request(%{meta: meta} = event, _config), do: %{event | meta: Map.delete(meta, :conn)}

  @doc "Attaches a handler that logs failed Oban jobs with worker, id, attempt and reason."
  def attach_job_failures do
    :telemetry.detach("sikio-job-failures")

    :telemetry.attach(
      "sikio-job-failures",
      [:oban, :job, :exception],
      &__MODULE__.job_failed/4,
      nil
    )
  end

  # Feed refreshes log their own failures, with the feed.
  @doc false
  def job_failed(_event, _measurements, %{job: %{worker: "Sikio.Feeds.Refresh"}}, _config),
    do: :ok

  # telemetry detaches a handler that raises, so this handler rescues every exception.
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

  @doc """
  Parses `LOG_LEVEL` case-insensitively. Returns `:info` for `nil` or a blank value.
  Raises `ArgumentError` for any other value outside the allowed levels.
  """
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
