# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar.Shared do
  @moduledoc """
  Loads the sidebar once for all open pages of an account.

  A library change reaches every open page of the account at the same moment. Each page asks
  this process instead of the database. A load that started after a page saw the change already
  holds it, so one load serves every page asking at the time.

  It also names the feeds an event reaches. A page that shows one source or tag skips the
  reread when its feeds are not among them.

  There is one process per account with open pages. It stops after a minute without requests.
  """
  use GenServer, restart: :temporary

  alias Sikio.Feeds
  alias SikioWeb.ReloadGate
  alias SikioWeb.Sidebar

  @idle_ms 60_000

  @doc """
  Returns the sidebar and the feeds `message` reaches, a list of feed ids or `:all`.

  `seen` is the `System.monotonic_time/0` at which the page received the event. The sidebar comes
  from a load that started no earlier.
  """
  def fetch(account, seen, message) do
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.call(server(account), {:fetch, account, seen, message, callers}, :infinity)
  catch
    # The process stopped between the lookup and the call, or its load failed. The page loads on
    # its own, through the gate, so a burst of such pages cannot exhaust the pool.
    :exit, _reason -> ReloadGate.run(fn -> {Sidebar.load(account), reach(message)} end)
  end

  defp server(account) do
    case Registry.lookup(__MODULE__, account.id) do
      [{pid, _}] -> pid
      [] -> start(account)
    end
  end

  defp start(account) do
    case DynamicSupervisor.start_child(SikioWeb.Sidebar.Supervisor, {__MODULE__, account.id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  def start_link(account_id), do: GenServer.start_link(__MODULE__, nil, name: via(account_id))

  defp via(id), do: {:via, Registry, {__MODULE__, id}}

  @impl true
  def init(nil), do: {:ok, %{sidebar: nil, loaded_at: nil, message: nil, reach: :all}}

  @impl true
  # Each load runs on behalf of the asking page, with its account. Its `$callers` let the test
  # sandbox allow the queries, as for a `Task`.
  def handle_call({:fetch, account, seen, message, callers}, _from, state) do
    Process.put(:"$callers", callers)
    state = state |> loaded(account, seen) |> reached(message)
    {:reply, {state.sidebar, state.reach}, state, @idle_ms}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp loaded(%{loaded_at: at} = state, _account, seen) when is_integer(at) and at >= seen,
    do: state

  defp loaded(state, account, _seen) do
    at = System.monotonic_time()
    %{state | sidebar: Sidebar.load(account), loaded_at: at}
  end

  # The pages ask about the same event one after another, so only the last one is kept.
  defp reached(%{message: message} = state, message), do: state
  defp reached(state, message), do: %{state | message: message, reach: reach(message)}

  defp reach({:playback_changed, %{entry_id: id}}), do: feed_of(id)

  defp reach({event, id}) when event in [:entry_saved, :entry_removed, :favourite_changed],
    do: feed_of(id)

  # A removed subscription also leaves its tags, and the new sidebar no longer maps them to its
  # feed. So it reaches every page, tag pages included.
  defp reach(_message), do: :all

  defp feed_of(entry_id) do
    case Feeds.feed_id_of(entry_id) do
      nil -> :all
      feed_id -> [feed_id]
    end
  end
end
