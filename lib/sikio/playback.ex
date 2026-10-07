# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Playback do
  @moduledoc """
  Account-scoped playback progress with serialized writes and stale-session protection.

  Browsers send progress several times a minute, from any number of tabs and devices.
  The network can delay and reorder these requests. Three mechanisms protect the stored position.
  Each change holds a row lock for its transaction, so two writes cannot interleave.
  One session owns an entry at a time, and starting a player creates a new session.
  Samples within a session carry an increasing sequence number.
  A late sample therefore cannot overwrite a newer one.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback.Preference
  alias Sikio.Playback.State
  alias Sikio.Repo

  # Bounds for browser-supplied position and duration, matching the database check constraints.
  defguardp valid_position(value) when is_number(value) and value >= 0 and value <= 31_536_000
  defguardp valid_duration(value) when is_nil(value) or (valid_position(value) and value > 0)

  @doc "Ends one player's session and keeps its last saved position."
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
  Starts a new player session for this entry, replacing any existing session.

  Without `at`, playback starts at `resume_position/1`. A heard entry therefore restarts at 0.
  Its heard status stays, since samples never lower it.

  `at` comes from the browser, because the card's seek bar works before the media loads.
  It is validated like a sample position. An invalid `at` starts at 0.
  """
  def start(%User{id: user_id} = account, id, at \\ nil) do
    reorder(account, id, fn state ->
      [
        session_id: Ecto.UUID.generate(),
        sequence: 0,
        position: starting_at(state, at),
        # As in Castro, a started entry goes to the head of the queue unless already queued.
        queue_rank: state.queue_rank || rank(user_id, :first)
      ]
    end)
  end

  defp starting_at(_state, at) when valid_position(at), do: at / 1
  defp starting_at(_state, at) when not is_nil(at), do: 0.0
  defp starting_at(state, nil), do: resume_position(state)

  @doc """
  Returns the resume position: the saved position, or 0 for a heard entry.
  `start/3` and the card's player before playback both use it.
  """
  def resume_position(%{status: :heard}), do: 0.0
  def resume_position(%{position: position}), do: position

  @doc """
  Sets the status manually and ends any player session on the entry.

  `:heard` can be set at any position. `:archived` sets the entry aside unheard.
  `:new` returns it to the inbox at position 0. Each status removes the entry from the queue.
  Other tabs receive the broadcast, and their next sample fails with `:stale`.
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

  @doc "Adds the entry to the queue, at the head or at the end."
  def enqueue(%User{id: user_id} = account, id, at) when at in [:first, :last],
    do: reorder(account, id, fn _state -> [queue_rank: rank(user_id, at)] end)

  # The account's queued playback rows, including those its lists hide.
  defp queued(user_id),
    do: from(p in State, where: p.user_id == ^user_id and not is_nil(p.queue_rank))

  # The queued rows the account's lists show, in playback order.
  # The entry id breaks ties, as in the queue list.
  defp visible_queue(account) do
    from p in queued(account.id),
      where: p.entry_id in subquery(Library.listed_entry_ids(account)),
      order_by: [asc: p.queue_rank, asc: p.entry_id]
  end

  # A rank before the account's first queued row, or after its last.
  defp rank(user_id, at) do
    ranks = queued(user_id)

    case at do
      :first -> (Repo.one(from p in ranks, select: min(p.queue_rank)) || 1.0) - 1.0
      :last -> (Repo.one(from p in ranks, select: max(p.queue_rank)) || 0.0) + 1.0
    end
  end

  @doc """
  Moves a queued entry to the 0-based `index` in the queue.
  Its new rank lies between its new neighbours, so other rows keep their ranks.
  The exception is a renumbering when no float fits between them.
  An index past the end moves the entry to the end.
  """
  def move(%User{id: user_id} = account, id, index) when is_integer(index) and index >= 0 do
    reorder(account, id, fn state ->
      if is_nil(state.queue_rank), do: Repo.rollback(:not_queued)

      # When no float fits between the neighbours, renumber the queue and place again.
      rank =
        with :none <- place(others(account, state), index) do
          renumber(user_id)
          place(others(account, state), index)
        end

      [queue_rank: rank]
    end)
  end

  # The rank between the new neighbours, or :none when no float fits between them.
  defp place(others, index) do
    before = if index > 0, do: Enum.at(others, index - 1, List.last(others))
    next = Enum.at(others, index)
    rank = between(before, next)

    if (is_nil(before) or rank > before) and (is_nil(next) or rank < next), do: rank, else: :none
  end

  # The ranks of the account's other visible queued rows.
  defp others(account, state),
    do: Repo.all(from p in visible_queue(account), where: p.id != ^state.id, select: p.queue_rank)

  # Assigns whole-number ranks in the current order.
  # Hidden rows, such as those of unsubscribed sources, keep their relative places.
  # Dequeueing takes no queue lock, so each update skips a row dequeued since the read.
  defp renumber(user_id) do
    Repo.all(
      from p in queued(user_id), order_by: [asc: p.queue_rank, asc: p.entry_id], select: p.id
    )
    |> Enum.with_index(1)
    |> Enum.each(fn {id, rank} ->
      Repo.update_all(from(p in State, where: p.id == ^id and not is_nil(p.queue_rank)),
        set: [queue_rank: rank / 1]
      )
    end)
  end

  defp between(nil, nil), do: 0.0
  defp between(nil, next), do: next - 1.0
  defp between(before, nil), do: before + 1.0
  defp between(before, next), do: (before + next) / 2

  @doc "Whether the player continues with the queue when an item ends. Defaults to true."
  def play_on?(%User{id: user_id}),
    do: Repo.one(from p in Preference, where: p.user_id == ^user_id, select: p.play_on) != false

  @doc "Upserts the account's setting for continuing with the queue."
  def play_on(%User{id: user_id}, on) when is_boolean(on) do
    now = DateTime.utc_now()

    Repo.insert(
      %Preference{user_id: user_id, play_on: on, inserted_at: now, updated_at: now},
      on_conflict: [set: [play_on: on, updated_at: now]],
      conflict_target: :user_id,
      returning: true
    )
  end

  @doc "Removes the entry from the queue."
  def dequeue(account, id), do: change(account, id, fn _state -> [queue_rank: nil] end)

  @doc "Returns the account's visible queue as entry ids, in playback order."
  def queue(%User{} = account),
    do: Repo.all(from p in visible_queue(account), select: p.entry_id)

  @doc """
  Whether a broadcast state is at least as recent as the progress on screen.

  A view that applies an older state would undo a status just set manually.
  The comparison lives here, not in each view, because this module defines the ordering.
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

  @doc "Returns how many entries `mark_all/3` would mark with the same `filters` and `options`."
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
  Archives every entry the list for `filters` shows and returns `{:ok, count}` of changed rows.

  Archived entries do not appear in the history. Heard and archived entries stay unchanged.
  `in_progress: false` skips in-progress entries.
  `keep:` names one entry to skip, such as the one loaded in the reader's player.
  A marked entry's session is cleared, so its player's next sample fails with `:stale`.
  Entries without a playback row get one first.
  When `count` is positive, one `{:playback_marked, count}` broadcast goes to the account.
  """
  def mark_all(%User{id: user_id} = account, filters, options \\ []) do
    now = DateTime.utc_now()
    listed = Library.listed_ids(account, filters)

    {:ok, count} =
      Repo.transaction(fn ->
        # Archiving dequeues rows, so it takes the queue lock and waits for a running renumber.
        Library.lock_queue(user_id)

        # SQLite parses `ON CONFLICT` after a `SELECT` without `WHERE` as a join's `ON` clause.
        # Ecto drops a `WHERE true`, so the query uses a condition that always holds.
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

  # Optional exclusions for marking a list.
  # An unopened entry has no `state` row, so `keep:` matches on the entry id.
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

  # A rank change takes the queue lock before the row lock.
  # Every path takes the two locks in this order, which prevents deadlocks.
  defp reorder(account, id, changes), do: change(account, id, changes, queue: true)

  defp change(%User{id: user_id} = account, id, changes, opts \\ []) do
    result =
      Repo.transaction(fn ->
        if opts[:queue], do: Library.lock_queue(user_id)
        entry_id = Library.visible_entry_id(account, id) || Repo.rollback(:not_found)
        Repo.insert!(%State{user_id: user_id, entry_id: entry_id}, on_conflict: :nothing)
        # An unsubscribe may commit between the check above and this lock.
        state = locked(account, entry_id) || Repo.rollback(:not_found)
        persist(state, changes.(state))
      end)

    broadcast(account, result)
  end

  # A change that keeps status and queue rank broadcasts `:playback_progressed`.
  # Such a change moves no entry between lists or within the queue.
  # A view can then update one entry instead of reloading its list.
  defp broadcast(account, {:ok, {previous, state}}) do
    Events.broadcast(account, {event(state, previous), state})
    {:ok, state}
  end

  defp broadcast(_account, result), do: result

  defp event(%{status: status, queue_rank: rank}, {status, rank}), do: :playback_progressed
  defp event(_state, _previous), do: :playback_changed

  # Every write rechecks authorization, since the subscription may have been removed.
  # Without a subscription, no row is returned or locked.
  # The lock excludes the subquery's rows, so unsubscribes and feed refreshes never wait for it.
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
    do:
      {{state.status, state.queue_rank}, state |> Ecto.Changeset.change(attrs) |> Repo.update!()}

  # Samples never lower heard. Only `mark/3` clears it, so a replay stays heard.
  # Reaching 90 % of the duration or the end sets heard.
  # The 90 % threshold covers end credits that listeners skip.
  # An archived entry that plays again becomes in progress.
  defp status(%{status: :heard}, _sample, _duration), do: :heard
  defp status(_state, %{ended: true}, _duration), do: :heard

  defp status(_state, %{position: position}, duration)
       when is_number(duration) and position >= 0.9 * duration,
       do: :heard

  defp status(_state, %{position: position}, _duration) when position > 0, do: :in_progress
  defp status(state, _sample, _duration), do: state.status

  # When the entry was heard or archived. A repeated heard keeps the first timestamp.
  defp completed_at(%{status: :heard, completed_at: at}, :heard), do: at
  defp completed_at(_state, :heard), do: DateTime.utc_now()
  defp completed_at(state, :archived), do: state.completed_at
  defp completed_at(_state, _status), do: nil

  # The sample comes from a browser, so its shape is validated before use.
  # The bounds match the database check constraints.
  defp sample(%{"sequence" => seq, "position" => pos, "duration" => dur, "ended" => ended})
       when is_integer(seq) and seq > 0 and seq < 9_007_199_254_740_991 and
              valid_position(pos) and is_boolean(ended) and valid_duration(dur) do
    {:ok, %{sequence: seq, position: pos / 1, duration: if(dur, do: dur / 1), ended: ended}}
  end

  defp sample(_attrs), do: {:error, :invalid_progress}
end
