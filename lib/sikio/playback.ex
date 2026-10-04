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

  # A place and a length from a browser, bounded like the database's own constraints.
  defguardp valid_position(value) when is_number(value) and value >= 0 and value <= 31_536_000
  defguardp valid_duration(value) when is_nil(value) or (valid_position(value) and value > 0)

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

  Without a place it resumes where it was left. Replaying something already finished starts at the
  beginning, because that is what asking to play it again means. Its completed status stays, which
  `status/2` then refuses to lower.

  A place comes from a browser: the card's player can be dragged before anything loads. It is
  checked like a sample, and one that is not a place in an episode starts at the beginning.
  """
  def start(account, id, at \\ nil) do
    change(account, id, fn state ->
      [
        session_id: Ecto.UUID.generate(),
        sequence: 0,
        position: starting_at(state, at)
      ]
    end)
  end

  defp starting_at(_state, at) when valid_position(at), do: at / 1
  defp starting_at(_state, at) when not is_nil(at), do: 0.0
  defp starting_at(state, nil), do: resume_position(state)

  @doc """
  Where a player picks an entry up: where it was left, or the beginning of one heard to the end.
  The card shows its player there before anything plays, so both ask here.
  """
  def resume_position(%{status: :heard}), do: 0.0
  def resume_position(%{position: position}), do: position

  @doc """
  Sets the status by hand, and stops whatever player holds the entry.

  Heard may be set at any point, archived puts it aside unheard, and new returns it to the inbox
  from the beginning. Each takes the entry out of the queue. Clearing the session is what makes
  this reach other tabs: their next sample is refused as stale, and the notification tells them why.
  """
  def mark(account, id, status) when status in [:new, :heard, :archived] do
    change(account, id, fn state ->
      [
        status: status,
        session_id: nil,
        sequence: 0,
        queue_rank: nil,
        position: if(status == :new, do: 0.0, else: state.position),
        completed_at: if(status != :new, do: DateTime.utc_now())
      ]
    end)
  end

  @doc "Puts the entry into the queue, before everything in it or after it."
  def enqueue(%User{id: user_id} = account, id, at) when at in [:first, :last] do
    change(account, id, fn _state ->
      ranks = from(p in State, where: p.user_id == ^user_id and not is_nil(p.queue_rank))

      rank =
        case at do
          :first -> (Repo.one(from p in ranks, select: min(p.queue_rank)) || 1.0) - 1.0
          :last -> (Repo.one(from p in ranks, select: max(p.queue_rank)) || 0.0) + 1.0
        end

      [queue_rank: rank]
    end)
  end

  @doc "Takes the entry out of the queue."
  def dequeue(account, id), do: change(account, id, fn _state -> [queue_rank: nil] end)

  @doc "This account's queue as entry ids, first first."
  def queue(%User{id: user_id} = account) do
    Repo.all(
      from p in State,
        where: p.user_id == ^user_id and not is_nil(p.queue_rank),
        where: p.entry_id in subquery(Library.visible_entry_ids(account)),
        order_by: [asc: p.queue_rank, asc: p.id],
        select: p.entry_id
    )
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

    duration = sample.duration || state.duration
    status = status(state, sample, duration)

    persist(state,
      position: sample.position,
      duration: duration,
      sequence: sample.sequence,
      status: status,
      queue_rank: if(status == :heard, do: nil, else: state.queue_rank),
      completed_at: completed_at(state, status)
    )
  end

  @doc "How many entries `mark_all/3` would mark with the same `filters` and `options`."
  def markable(%User{id: user_id} = account, filters, options \\ []) do
    Repo.one(
      from e in subquery(Library.listed_ids(account, filters)),
        as: :entry,
        left_join: p in State,
        as: :state,
        on: p.entry_id == e.id and p.user_id == ^user_id,
        where: is_nil(p.id) or p.status not in [:heard, :archived],
        where: ^leaving_out(options),
        select: count()
    )
  end

  @doc """
  Archives everything a list with `filters` shows, and answers how many changed.

  Putting a list aside is not hearing it, so none of it reaches the history. What is heard or
  archived already stays as it was. `in_progress: false` leaves what is in progress, and
  `keep:` names an entry to leave, the one the reader's player holds. A player that held a marked
  entry hears its progress changed elsewhere, as after marking one by hand. An entry nobody opened
  gets its row first. The views hear of it once, as `{:playback_marked, count}`.
  """
  def mark_all(%User{id: user_id} = account, filters, options \\ []) do
    now = DateTime.utc_now()
    listed = Library.listed_ids(account, filters)

    {:ok, count} =
      Repo.transaction(fn ->
        # SQLite reads `ON CONFLICT` after a `SELECT` without `WHERE` as a join's `ON`, and Ecto
        # drops a `WHERE true`, so the condition is one that always holds but stays.
        Repo.insert_all(
          State,
          from(e in subquery(listed),
            where: not is_nil(e.id),
            select: %{user_id: ^user_id, entry_id: e.id, inserted_at: ^now, updated_at: ^now}
          ),
          on_conflict: :nothing
        )

        {count, _} =
          Repo.update_all(
            from(p in State,
              as: :state,
              join: e in subquery(listed),
              as: :entry,
              on: e.id == p.entry_id,
              where: p.user_id == ^user_id and p.status not in [:heard, :archived],
              where: ^leaving_out(options)
            ),
            set: [
              status: :archived,
              queue_rank: nil,
              completed_at: now,
              session_id: nil,
              sequence: 0,
              updated_at: now
            ]
          )

        count
      end)

    if count > 0, do: Events.broadcast(account, {:playback_marked, count})
    {:ok, count}
  end

  # What marking a list leaves out on request. `state` is the entry's progress, which an entry
  # nobody opened has none of, so the kept entry is named by the entry's own id.
  defp leaving_out(options) do
    in_progress =
      if Keyword.get(options, :in_progress, true),
        do: true,
        else: dynamic([state: p], is_nil(p.id) or p.status != :in_progress)

    case options[:keep] do
      nil -> in_progress
      id -> dynamic([entry: e], ^in_progress and e.id != ^id)
    end
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
        from(p in State,
          where: p.user_id == ^user_id and p.entry_id == ^id,
          where: p.entry_id in subquery(Library.visible_entry_ids(account))
        )
        |> Repo.for_update()
        |> Repo.one()

      _ ->
        nil
    end
  end

  defp persist(state, attrs),
    do: {state.status, state |> Ecto.Changeset.change(attrs) |> Repo.update!()}

  # Heard is a floor. Reaching 90 % of the length or the end sets it, and nothing but an explicit
  # mark as new takes it away, so replaying an episode does not make it unheard again. Many end on
  # credits nobody waits for. An archived episode played after all is under way again.
  defp status(%{status: :heard}, _sample, _duration), do: :heard
  defp status(_state, %{ended: true}, _duration), do: :heard

  defp status(_state, %{position: position}, duration)
       when is_number(duration) and position >= 0.9 * duration,
       do: :heard

  defp status(_state, %{position: position}, _duration) when position > 0, do: :in_progress
  defp status(state, _sample, _duration), do: state.status

  # When it was heard or put aside. Hearing it again keeps the first time.
  defp completed_at(%{status: :heard, completed_at: at}, :heard), do: at
  defp completed_at(_state, :heard), do: DateTime.utc_now()
  defp completed_at(state, :archived), do: state.completed_at
  defp completed_at(_state, _status), do: nil

  # The sample comes from a browser, so its shape is checked before any of it is believed. The
  # bounds match the database's own constraints.
  defp sample(%{"sequence" => seq, "position" => pos, "duration" => dur, "ended" => ended})
       when is_integer(seq) and seq > 0 and seq < 9_007_199_254_740_991 and
              valid_position(pos) and is_boolean(ended) and valid_duration(dur) do
    {:ok, %{sequence: seq, position: pos / 1, duration: if(dur, do: dur / 1), ended: ended}}
  end

  defp sample(_attrs), do: {:error, :invalid_progress}
end
