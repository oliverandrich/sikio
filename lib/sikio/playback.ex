# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Playback do
  @moduledoc """
  Account-scoped progress with serialized writes and stale-session protection.

  Progress arrives from a browser several times a minute, from any number of tabs and devices, and
  the network reorders and delays it. Three things keep that from corrupting a position. The row is
  locked for the length of each change, so two writes cannot interleave. One session owns an entry
  at a time, and starting a player anywhere mints a new one. Within a session, samples carry a
  rising sequence, so a late message cannot undo a newer one.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback.State
  alias Sikio.Repo

  @doc "Closes one player's session, keeping the position it last saved."
  def stop(account, id, session) do
    result =
      Repo.transaction(fn ->
        state = locked(account, id)

        if is_nil(state) or is_nil(session) or state.session_id != session,
          do: Repo.rollback(:stale)

        persist(state, session_id: nil)
      end)

    broadcast(account, result)
  end

  @doc """
  Takes over this entry for a new player.

  Replaying something already finished starts at the beginning, because that is what asking to play
  it again means. Its completed status stays, which `status/2` then refuses to lower.
  """
  def start(account, id) do
    change(account, id, fn state ->
      [
        session_id: Ecto.UUID.generate(),
        sequence: 0,
        position: if(state.status == :completed, do: 0.0, else: state.position)
      ]
    end)
  end

  @doc """
  Sets the status by hand, and stops whatever player holds the entry.

  Clearing the session is what makes this reach other tabs: their next sample is refused as stale,
  and the notification tells them why.
  """
  def mark(account, id, status) when status in [:new, :completed] do
    change(account, id, fn state ->
      [
        status: status,
        session_id: nil,
        sequence: 0,
        position: if(status == :new, do: 0.0, else: state.position),
        completed_at: if(status == :completed, do: DateTime.utc_now())
      ]
    end)
  end

  @doc """
  Whether a notification says something newer than the progress already on screen.

  A view that acts on an older one undoes a status somebody just set by hand. Written here rather
  than in each view, because this is the module that decides what newer means.
  """
  def newer?(%{playback: nil}, _state), do: true

  def newer?(%{playback: current}, state),
    do: DateTime.compare(state.updated_at, current.updated_at) != :lt

  def save(account, id, session, attrs) do
    with {:ok, sample} <- sample(attrs) do
      broadcast(account, Repo.transaction(fn -> save_sample(account, id, session, sample) end))
    end
  end

  defp save_sample(account, id, session, sample) do
    state = locked(account, id)

    if is_nil(state) or is_nil(session) or state.session_id != session or
         state.sequence >= sample.sequence do
      Repo.rollback(:stale)
    end

    status = status(state, sample)

    persist(state,
      position: sample.position,
      duration: sample.duration || state.duration,
      sequence: sample.sequence,
      status: status,
      completed_at: if(status == :completed, do: state.completed_at || DateTime.utc_now())
    )
  end

  defp change(%User{id: user_id} = account, id, changes) do
    result =
      Repo.transaction(fn ->
        entry_id = Library.visible_entry_id(account, id) || Repo.rollback(:not_found)
        Repo.insert!(%State{user_id: user_id, entry_id: entry_id}, on_conflict: :nothing)
        # An unsubscribe may commit between the check above and this lock.
        state = locked(account, entry_id) || Repo.rollback(:not_found)
        persist(state, changes.(state))
      end)

    broadcast(account, result)
  end

  # A change that keeps the status is announced as progress. It cannot move an item between
  # views, so a view can update the one item instead of reading its list again.
  defp broadcast(account, {:ok, {previous_status, state}}) do
    Events.broadcast(account, {event(state, previous_status), state})
    {:ok, state}
  end

  defp broadcast(_account, result), do: result

  defp event(%{status: status}, status), do: :playback_progressed
  defp event(_state, _previous_status), do: :playback_changed

  # Authorization is rechecked with every write, rather than trusted from the request that started
  # the player: a subscription may have been removed since. Without one there is nothing to lock.
  # A subquery is not locked, so an unsubscribe or a feed refresh never waits for a player.
  defp locked(%User{id: user_id} = account, id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} ->
        Repo.one(
          from p in State,
            where: p.user_id == ^user_id and p.entry_id == ^id,
            where: p.entry_id in subquery(Library.visible_entry_ids(account)),
            lock: "FOR UPDATE"
        )

      _ ->
        nil
    end
  end

  defp persist(state, attrs),
    do: {state.status, state |> Ecto.Changeset.change(attrs) |> Repo.update!()}

  # Completion is a floor. Only reaching the end sets it, and nothing but an explicit mark as new
  # takes it away, so replaying an episode does not make it unfinished again.
  defp status(%{status: :completed}, _sample), do: :completed
  defp status(_state, %{ended: true}), do: :completed
  defp status(_state, %{position: position}) when position > 0, do: :in_progress
  defp status(state, _sample), do: state.status

  defguardp valid_position(value) when is_number(value) and value >= 0 and value <= 31_536_000
  defguardp valid_duration(value) when is_nil(value) or (valid_position(value) and value > 0)

  # The sample comes from a browser, so its shape is checked before any of it is believed. The
  # bounds match the database's own constraints.
  defp sample(%{"sequence" => seq, "position" => pos, "duration" => dur, "ended" => ended})
       when is_integer(seq) and seq > 0 and seq < 9_007_199_254_740_991 and
              valid_position(pos) and is_boolean(ended) and valid_duration(dur) do
    {:ok, %{sequence: seq, position: pos / 1, duration: if(dur, do: dur / 1), ended: ended}}
  end

  defp sample(_attrs), do: {:error, :invalid_progress}
end
