defmodule Octoroom.Room.Server do
  @moduledoc false

  # One room. The single writer of the room's state: participants, the track
  # directory and every browser session's subscriptions. Cloudflare calls run
  # in tasks; their results come back as messages, update the actual state
  # and trigger another reconcile.
  #
  # Each browser has one Cloudflare session. Only one operation (a batched
  # pull or a batched close) is in flight per session, because each needs an
  # offer/answer exchange with the browser.
  #
  # Pull:  Cloudflare `tracks/new` -> Cloudflare's offer to the browser
  #        (`:renegotiate`) -> browser's answer -> Cloudflare `renegotiate`
  #        -> `:tracks` added.
  # Close: `:close` to the browser -> the browser stops the transceivers and
  #        sends an offer -> Cloudflare `tracks/close` -> answer to the
  #        browser -> `:tracks` removed.
  #
  # Workers: the room server starts, stops and restarts workers (under the
  # room's workers supervisor) to match `workers/1`, and owns their media.
  # Each worker with media has a peer (`Octoroom.Peer`: its own Cloudflare
  # session and peer connection), each output track an outlet and each
  # (worker, live input) an inlet, all under the room's media supervisor.
  # The room server tells a worker's peer what to push, pull and close, and
  # hears back as `{:peer_result, ...}`. An output track is `:pending` once
  # it's pushed and `:live` once its outlet has sent a packet. A peer stops
  # when its worker has no media left; its session ends with its peer
  # connection, so nothing at Cloudflare needs closing.
  #
  # Publishing: a participant's first `publish` creates its session and
  # pushes the sources in its offer (usually the mic, maybe the camera).
  # Sources published later (a camera turned on, a screen share) and
  # unpublished go through the same per-session queue as pulls and closes:
  #
  # Push:    `publish_tracks` -> `:push` to the browser -> the browser adds
  #          transceivers and sends an offer -> Cloudflare `tracks/new`
  #          (local) -> answer to the browser -> `connected` once it flows.
  # Unpush:  `unpublish` -> the track leaves the directory, so pulls of it
  #          close -> once none are left, `:close` of its mid to the
  #          browser, as for a pull.
  #
  # Messages to a participant's process (its channel) are
  # `{:octoroom_signal, kind, payload}`; replies to its requests are
  # `{:octoroom_signal, :reply, tag, result}`.

  use GenServer, restart: :temporary

  require Logger

  alias Octoroom.{Cloudflare, Inlet, Outlet, Participant, Peer, Reconciler, Room, Store, Track}
  alias Octoroom.Worker

  @max_failures 5
  @signal_timeout 15_000
  # How long a participant whose connection dropped is kept, and how long a
  # recovered room holds subscriptions to participants who haven't resumed.
  # A minute, because browsers throttle timers in background tabs: Chrome
  # may hold a hidden tab's reconnect back for up to a minute (one measured
  # resume took 37 s after the server was back). Holding a subscription
  # nobody is sending on costs nothing.
  @grace_ms 60_000
  # How often the room record's `updated_at` is refreshed, so a recovered
  # room knows about how long it was down.
  @heartbeat_ms 5_000
  # A worker that ran this long before crashing starts its backoff afresh.
  @worker_stable_ms 30_000

  ## API (called by a participant's process)

  # Each start of a room server is a new run. The run id is the registry
  # value, so `run/1` answers without calling the server (the janitor asks
  # whether a room is running).
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    run = new_id()
    name = {:via, Registry, {Octoroom.Registry, {:room, room_id}, run}}
    GenServer.start_link(__MODULE__, Keyword.put(opts, :run, run), name: name)
  end

  @doc "The run of the room server running `room_id` on this node, or nil."
  def run(room_id) do
    case Registry.lookup(Octoroom.Registry, {:room, room_id}) do
      [{_pid, run}] -> run
      [] -> nil
    end
  end

  def whereis(room_id) do
    case Registry.lookup(Octoroom.Registry, {:room, room_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Creates the participant's session and publishes the sources in its offer
  (`mids`: source => mid, e.g. `%{"mic" => "0"}`). Replies `%{sdp: answer}`.
  """
  def publish(server, participant_id, sdp, mids, tag),
    do: GenServer.cast(server, {:publish, participant_id, sdp, mids, tag})

  @doc """
  Publishes more sources on the participant's session. Queued: the
  participant gets `:push` when it's their turn and answers with
  `push_offer/6`. Replies `%{}` once Cloudflare has the tracks.
  """
  def publish_tracks(server, participant_id, sources, tag),
    do: GenServer.cast(server, {:publish_tracks, participant_id, sources, tag})

  @doc "The participant's offer for a `:push`, with the new transceivers' mids. Replies `%{sdp: answer}`."
  def push_offer(server, participant_id, op_id, sdp, mids, tag),
    do: GenServer.cast(server, {:push_offer, participant_id, op_id, sdp, mids, tag})

  @doc "Stops publishing a source: closes every pull of it, then its own track. Replies `%{}` when done."
  def unpublish(server, participant_id, source, tag),
    do: GenServer.cast(server, {:unpublish, participant_id, source, tag})

  @doc "Marks a published source muted or not. Nothing renegotiates."
  def mute(server, participant_id, source, muted),
    do: GenServer.cast(server, {:mute, participant_id, source, muted})

  @doc """
  The participant's connection to Cloudflare is up, so what it published is
  flowing. `timings` are the client's own measurements of its join (see
  `Octoroom.Telemetry`), already checked by the channel.
  """
  def connected(server, participant_id, timings \\ %{}),
    do: GenServer.cast(server, {:connected, participant_id, timings})

  @doc "The participant's answer to a `:renegotiate` offer."
  def answer(server, participant_id, op_id, sdp, tag),
    do: GenServer.cast(server, {:answer, participant_id, op_id, sdp, tag})

  @doc "The participant's offer after stopping the transceivers of a `:close`. Replies `%{sdp: answer}`."
  def close_offer(server, participant_id, op_id, sdp, tag),
    do: GenServer.cast(server, {:close_offer, participant_id, op_id, sdp, tag})

  def leave(server, participant_id), do: GenServer.cast(server, {:leave, participant_id})

  ## Server

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    module = Keyword.fetch!(opts, :module)
    store = Keyword.get_lazy(opts, :store, &Store.config/0)
    # So `terminate/2` runs when the room shuts down.
    Process.flag(:trap_exit, true)

    # A record left behind means the previous run didn't stop cleanly (a
    # crash, a restart, a deploy): this run recovers the room.
    previous = Store.get(store, :rooms, room_id)

    case mount(%{id: room_id, module: module}, previous) do
      {:ok, assigns} -> init_state(opts, store, previous, assigns)
      # Fails the join that started the room, with a reason that says why.
      {:error, reason} -> {:stop, {:mount_failed, reason}}
    end
  end

  defp mount(_room, %{assigns: assigns}), do: {:ok, assigns}

  defp mount(room, nil) do
    case call_room(fn -> room.module.mount(room.id) end, &match?({:ok, %{}}, &1), "{:ok, map}") do
      {:ok, {:ok, assigns}} ->
        {:ok, assigns}

      {:error, {reason, _} = error} ->
        policy_failed(room, :mount, error)
        {:error, reason}
    end
  end

  defp init_state(opts, store, previous, assigns) do
    room_id = Keyword.fetch!(opts, :room_id)
    module = Keyword.fetch!(opts, :module)
    run = Keyword.fetch!(opts, :run)
    # The room id goes along to tag telemetry of Cloudflare calls.
    cf = opts |> Keyword.get_lazy(:cloudflare, &Cloudflare.config/0) |> Map.put(:room_id, room_id)
    now = Store.now()
    Store.put(store, :rooms, room_id, %{run: run, assigns: assigns, updated_at: now})
    # A fresh room: what workers saved belongs to an earlier one that
    # stopped (a worker can save while the room stops).
    if previous == nil, do: Worker.forget_room(store, room_id)
    grace_ms = Keyword.get(opts, :grace_ms, @grace_ms)
    heartbeat_ms = Keyword.get(opts, :heartbeat_ms, @heartbeat_ms)
    Process.send_after(self(), :heartbeat, heartbeat_ms)
    if previous, do: Process.send_after(self(), :grace_over, grace_ms)

    :telemetry.execute([:octoroom, :room, :start], %{}, %{
      room_id: room_id,
      run: run,
      recovered: previous != nil
    })

    {:ok,
     %{
       id: room_id,
       run: run,
       module: module,
       store: store,
       assigns: assigns,
       # Set while a recovered room is in its grace period.
       recovering: if(previous, do: %{gone_ms: max(now - previous.updated_at, 0)}),
       # Tracks of participants who haven't resumed yet, still pulled by
       # someone who has: name => %{session_id, track_name}. Held until they
       # resume or the grace period ends.
       ghosts: %{},
       grace_ms: grace_ms,
       heartbeat_ms: heartbeat_ms,
       cloudflare: cf,
       signal_timeout: Keyword.get(opts, :signal_timeout, @signal_timeout),
       # Failures back off retry_base_ms * 2^n: 0.5 s, 1 s, 2 s, ...
       retry_base_ms: Keyword.get(opts, :retry_base_ms, 250),
       # The peer connection under workers' peers (`Octoroom.Peer.Media`).
       peer_media: Keyword.get(opts, :peer_media, Octoroom.Peer.WebRTC),
       participants: %{},
       worker_specs: [],
       workers: %{},
       # worker id => %{state, attributes}, what it last set with `presence:`.
       presence: %{},
       # participant id => %{output name => worker id}: the worker outputs,
       # audio (pull open) or data, each participant receives, as of the
       # last reconcile.
       seen: %{},
       # worker id => its peer
       peers: %{},
       outlets: %{},
       inlets: %{},
       order: [],
       failures: %{},
       # Policy callbacks failing as of the last reconcile: `:workers` or
       # `{:subscriptions, participant_id}` => reason. Each is reported when
       # it starts failing or fails differently, not on every pass.
       policy_errors: %{},
       retry: nil
     }}
  end

  @impl true
  # Metadata comes from the app's `join/2`, which may pass client params
  # through. Metadata of the wrong shape would crash the room on the
  # participant's first publish, so it's refused here. A room started for
  # this join stops again, unless it's recovering.
  def handle_call({:join, pid, meta}, _from, state) do
    if meta?(meta) do
      p = new_participant(new_id(), meta, pid)
      state = add_participant(state, p)
      :telemetry.execute([:octoroom, :participant, :join], %{}, %{room_id: state.id, id: p.id})
      # The participant can't hear or be heard yet, but workers may follow it.
      {:reply, {:ok, join_reply(state, p, false)}, reconcile(state)}
    else
      reply = {:error, {:bad_meta, meta}}

      # A recovering room keeps running (and its record) for those resuming.
      if state.participants == %{} and state.recovering == nil,
        do: {:stop, :normal, reply, state},
        else: {:reply, reply, state}
    end
  end

  # A client coming back with its resume token's data.
  def handle_call({:resume, pid, data}, _from, state) do
    %{participant_id: id, meta: meta} = data
    session_id = Map.get(data, :session_id)
    meta_ = %{room_id: state.id, id: id}

    case state.participants[id] do
      # Its connection dropped and came back while the room kept running:
      # nothing at Cloudflare changed, so only the channel is replaced.
      %{} = p ->
        if p.monitor, do: Process.demonitor(p.monitor, [:flush])
        cancel(p.disconnected)
        p = %{p | pid: pid, monitor: Process.monitor(pid), disconnected: nil}
        state = put_p(state, p)

        :telemetry.execute(
          [:octoroom, :participant, :resume],
          %{},
          Map.put(meta_, :kind, :rejoin)
        )

        {:reply, {:ok, join_reply(state, p, true)}, resync(state, p)}

      # Never published: nothing to adopt, so it starts over.
      nil when session_id == nil ->
        p = new_participant(id, meta, pid)
        state = add_participant(state, p)
        :telemetry.execute([:octoroom, :participant, :join], %{}, meta_)
        {:reply, {:ok, join_reply(state, p, false)}, reconcile(state)}

      # The room restarted (or this participant was dropped): adopt its
      # Cloudflare session as it is.
      nil ->
        p = %{new_participant(id, meta, pid) | session_id: session_id, media: :adopting}
        state = add_participant(state, p)
        cf = state.cloudflare
        run(state, id, :adopt, fn -> Cloudflare.session_state(cf, session_id) end)
        :telemetry.execute([:octoroom, :participant, :resume], %{}, Map.put(meta_, :kind, :adopt))
        {:reply, {:ok, join_reply(state, p, true)}, state}
    end
  end

  def handle_call({:update_meta, id, fun}, _from, state) do
    case state.participants[id] do
      nil ->
        {:reply, {:error, :no_participant}, state}

      p ->
        expected = "a map, with :publish a list of source names if present"

        case call_room(fn -> fun.(p.meta) end, &meta?/1, expected) do
          {:ok, meta} ->
            p = %{p | meta: meta}
            state = put_in(state.participants[id], p)
            event(state, {:updated, public(p)})
            signal(p, :resume, resume_data(p))
            {:reply, :ok, reconcile(state)}

          {:error, {reason, _} = error} ->
            policy_failed(state, {:update_meta, id}, error)
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:assign, key, value}, _from, state) do
    state = %{state | assigns: Map.put(state.assigns, key, value)}
    put_room_record(state)
    {:reply, :ok, reconcile(state)}
  end

  def handle_call(:refresh, _from, state), do: {:reply, :ok, reconcile(state)}

  def handle_call(:state, _from, state) do
    snapshot = %{
      id: state.id,
      assigns: state.assigns,
      participants:
        for p <- participants(state) do
          %{
            id: p.id,
            meta: p.meta,
            media: p.media,
            mic: mic_status(p),
            tracks: Map.new(p.tracks, fn {src, t} -> {src, Map.take(t, [:status, :muted])} end),
            hears: for({name, %{status: :open}} <- p.subs, do: name) |> Enum.sort(),
            data: p.data_subs |> MapSet.to_list() |> Enum.sort(),
            subscriptions:
              Map.new(p.subs, fn {name, s} -> {name, Map.take(s, [:status, :gain])} end)
          }
        end,
      workers:
        for spec <- state.worker_specs do
          running = state.workers[spec.id]

          spec
          |> Map.take([:id, :module, :inputs, :outputs, :data])
          |> Map.merge(%{
            running: running != nil,
            state: get_in(state.presence, [spec.id, :state]),
            attributes: get_in(state.presence, [spec.id, :attributes]) || %{},
            connected:
              for({{id, input}, %{status: :connected}} <- state.inlets, id == spec.id, do: input)
              |> Enum.sort(),
            # Input frames dropped to hold each input to real time.
            dropped:
              for {{id, input}, inlet} <- state.inlets, id == spec.id, into: %{} do
                {input, inlet_dropped(inlet.pid)}
              end
          })
        end,
      outputs:
        Map.new(state.outlets, fn {name, o} ->
          {name, %{status: o.status, worker: o.worker_id}}
        end)
    }

    {:reply, snapshot, state}
  end

  # Requests carry what a browser sent. The channel checks their shape, but
  # the server is called without it too (`Room.join/4` is public), and a
  # payload that raises here would take the whole room down. Values of the
  # right shape that are still wrong (an unknown source, a stale op id) are
  # refused further in.
  @impl true
  def handle_cast(request, state) do
    if well_formed?(request) do
      cast(request, state)
    else
      with %{} = p <- state.participants[elem(request, 1)],
           do: reply(p, request_tag(request), {:error, :bad_payload})

      {:noreply, state}
    end
  end

  defp well_formed?({:publish, _, sdp, mids, _}), do: is_binary(sdp) and mids?(mids)

  defp well_formed?({:publish_tracks, _, sources, _}),
    do: is_list(sources) and Enum.all?(sources, &source?/1)

  defp well_formed?({:push_offer, _, op_id, sdp, mids, _}),
    do: is_binary(op_id) and is_binary(sdp) and mids?(mids)

  defp well_formed?({:unpublish, _, source, _}), do: source?(source)
  defp well_formed?({:mute, _, source, muted}), do: source?(source) and is_boolean(muted)

  defp well_formed?({kind, _, op_id, sdp, _}) when kind in [:answer, :close_offer],
    do: is_binary(op_id) and is_binary(sdp)

  defp well_formed?(_request), do: true

  # Source names are strings from a browser; atoms are accepted from Elixir
  # callers, as `to_string/1` below turns them into the same names.
  defp source?(source), do: is_binary(source) or is_atom(source)

  defp mids?(mids),
    do:
      is_map(mids) and Enum.all?(mids, fn {source, mid} -> source?(source) and is_binary(mid) end)

  # `mute` has no reply.
  defp request_tag({:mute, _, _, _}), do: nil
  defp request_tag(request), do: elem(request, tuple_size(request) - 1)

  defp cast({:publish, id, sdp, mids, tag}, state) do
    with_participant(state, id, fn
      %{media: :none} = p ->
        mids = Map.new(mids, fn {source, mid} -> {to_string(source), mid} end)

        case check_sources(p, Map.keys(mids)) do
          :ok ->
            cf = state.cloudflare

            tracks =
              for {source, mid} <- mids, do: %{mid: mid, track_name: track_name(id, source)}

            p = %{p | timeline: %{joined: p.timeline.joined, publish: now_ms()}}

            run(state, id, :publish, fn ->
              with {:ok, session} <- Cloudflare.new_session(cf),
                   {:ok, %{sdp: answer}} <- Cloudflare.push_tracks(cf, session, sdp, tracks) do
                {:ok, session, answer}
              end
            end)

            put_p(state, %{p | media: :publishing, publish_tag: tag, publishing: mids})

          {:error, reason} ->
            reply(p, tag, {:error, reason})
            state
        end

      p ->
        reply(p, tag, {:error, :already_published})
        state
    end)
  end

  defp cast({:publish_tracks, id, sources, tag}, state) do
    with_participant(state, id, fn p ->
      sources = Enum.map(sources, &to_string/1)

      queued =
        for {:push, srcs, _} <- p.requests, src <- srcs, do: src

      result =
        cond do
          p.media != :live ->
            {:error, :not_connected}

          Enum.any?(sources, &(Map.has_key?(p.tracks, &1) or &1 in queued)) ->
            {:error, :already_published}

          true ->
            check_sources(p, sources)
        end

      case result do
        :ok ->
          state
          |> put_p(%{p | requests: p.requests ++ [{:push, Enum.uniq(sources), tag}]})
          |> reconcile()

        {:error, reason} ->
          reply(p, tag, {:error, reason})
          state
      end
    end)
  end

  defp cast({:push_offer, id, op_id, sdp, mids, tag}, state) do
    with_op(state, id, op_id, :awaiting_push_offer, tag, fn p, op ->
      cancel(op.timer)
      mids = Map.new(mids, fn {source, mid} -> {to_string(source), mid} end)

      if Enum.sort(Map.keys(mids)) == Enum.sort(op.sources) do
        cf = state.cloudflare
        tracks = for {source, mid} <- mids, do: %{mid: mid, track_name: track_name(id, source)}

        run(state, id, {:pushed, op_id}, fn ->
          Cloudflare.push_tracks(cf, p.session_id, sdp, tracks)
        end)

        put_p(state, %{p | op: %{op | stage: :pushing, tag: tag, timer: nil, mids: mids}})
      else
        reply(p, tag, {:error, :wrong_sources})
        reply(p, op.request_tag, {:error, :wrong_sources})
        state |> put_p(%{p | op: nil}) |> reconcile()
      end
    end)
  end

  defp cast({:unpublish, id, source, tag}, state) do
    with_participant(state, id, fn p ->
      source = to_string(source)

      case p.tracks[source] do
        %{status: status} = t when status in [:pending, :live] ->
          # Out of the directory: pulls of it close, then its own track does.
          p = %{
            p
            | tracks: Map.put(p.tracks, source, %{t | status: :closing}),
              requests: p.requests ++ [{:unpush, source, tag}]
          }

          state = put_p(state, p)
          if status == :live, do: event(state, {:updated, public(p)})
          reconcile(state)

        _ ->
          reply(p, tag, {:error, :not_published})
          state
      end
    end)
  end

  defp cast({:mute, id, source, muted}, state) do
    with_participant(state, id, fn p ->
      source = to_string(source)

      case p.tracks[source] do
        %{muted: was} = t when was != muted and is_boolean(muted) ->
          p = put_in(p.tracks[source], %{t | muted: muted})
          state = put_p(state, p)
          if t.status == :live, do: event(state, {:updated, public(p)})
          state

        _ ->
          state
      end
    end)
  end

  defp cast({:connected, id, timings}, state) do
    with_participant(state, id, fn p ->
      pending = for {source, %{status: :pending}} <- p.tracks, do: source
      p = connected_telemetry(state, p, timings)
      state = put_p(state, p)

      if p.media == :pending or pending != [] do
        media = if p.media == :pending, do: :live, else: p.media
        tracks = Enum.reduce(pending, p.tracks, &put_in(&2[&1].status, :live))
        p = %{p | media: media, tracks: tracks}
        state = put_p(state, p)
        # Earlier pulls of these tracks may have failed while they were empty.
        names = MapSet.new(pending, &track_name(id, &1))
        failures = Map.reject(state.failures, fn {{_, n}, _} -> MapSet.member?(names, n) end)
        event(state, {:published, public(p)})
        reconcile(%{state | failures: failures})
      else
        state
      end
    end)
  end

  defp cast({:answer, id, op_id, sdp, tag}, state) do
    with_op(state, id, op_id, :awaiting_answer, tag, fn p, op ->
      cancel(op.timer)
      cf = state.cloudflare

      run(state, id, {:renegotiated, op_id}, fn ->
        Cloudflare.renegotiate(cf, p.session_id, sdp)
      end)

      put_p(state, %{p | op: %{op | stage: :renegotiating, tag: tag, timer: nil}})
    end)
  end

  defp cast({:close_offer, id, op_id, sdp, tag}, state) do
    with_op(state, id, op_id, :awaiting_offer, tag, fn p, op ->
      cancel(op.timer)
      cf = state.cloudflare
      mids = op.mids

      run(state, id, {:closed, op_id}, fn ->
        Cloudflare.close_tracks(cf, p.session_id, mids, sdp)
      end)

      put_p(state, %{p | op: %{op | stage: :closing, tag: tag, timer: nil}})
    end)
  end

  defp cast({:leave, id}, state), do: remove(state, id, :left)

  @impl true
  def handle_info({:result, id, kind, result}, state) do
    case state.participants[id] do
      nil -> {:noreply, state}
      p -> handle_result(state, p, kind, result)
    end
  end

  def handle_info({:signal_timeout, id, op_id}, state) do
    case state.participants[id] do
      # Disconnected: the request is sent again when it resumes.
      %{op: %{id: ^op_id}, pid: nil} ->
        {:noreply, state}

      %{op: %{id: ^op_id}} = p ->
        Logger.warning("Octoroom participant #{id} didn't answer signaling in time")
        signal(p, :kick, :signaling_timeout)
        remove(state, id, :kicked)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:retry, state), do: {:noreply, reconcile(%{state | retry: nil})}

  def handle_info({:disconnect_expired, id, ref}, state) do
    case state.participants[id] do
      %{disconnected: ^ref} -> remove(state, id, :left)
      _ -> {:noreply, state}
    end
  end

  # Whoever hasn't resumed by now has left.
  def handle_info(:grace_over, state) do
    :telemetry.execute([:octoroom, :room, :recovered], %{ghosts: map_size(state.ghosts)}, %{
      room_id: state.id
    })

    {:noreply, reconcile(%{state | recovering: nil, ghosts: %{}})}
  end

  def handle_info(:heartbeat, state) do
    put_room_record(state)
    Process.send_after(self(), :heartbeat, state.heartbeat_ms)
    {:noreply, state}
  end

  def handle_info({:outlet_live, name, pid}, state) do
    case state.outlets[name] do
      %{pid: ^pid, status: :creating} = o ->
        {:noreply, put_in(state.outlets[name], %{o | live_seen: true})}

      %{pid: ^pid, status: :pending} = o ->
        state = put_in(state.outlets[name], %{o | status: :live})
        failures = Map.reject(state.failures, fn {{_, n}, _} -> n == name end)
        output_live(state, name, o)
        {:noreply, reconcile(%{state | failures: failures})}

      _ ->
        {:noreply, state}
    end
  end

  # A worker's output started talking again. Listeners whose pulls of it
  # failed (Cloudflare can answer "track not found" for a track that has
  # just started, or gone quiet) try again now, even ones that gave up.
  def handle_info({:outlet_spurt, name, pid}, state) do
    case state.outlets[name] do
      %{pid: ^pid, status: :live} ->
        {cleared, failures} =
          Map.split_with(state.failures, fn {{id, n}, _} -> n == name and is_binary(id) end)

        if cleared == %{},
          do: {:noreply, state},
          else: {:noreply, reconcile(%{state | failures: failures})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:peer_result, worker_id, pid, result}, state) do
    case state.peers[worker_id] do
      %{pid: ^pid} -> {:noreply, state |> peer_result(worker_id, result) |> reconcile()}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case monitored(state, ref) do
      # The client's channel shut down without the client leaving: its
      # connection dropped (`{:shutdown, :closed}`), the node is draining
      # sockets (`{:shutdown, :restart}`) or stopping (`:shutdown`). It may
      # come back with its resume token: until then its subscriptions stay
      # as they are. `{:shutdown, :left}` is the client leaving.
      {:participant, id}
      when reason != {:shutdown, :left} and
             (reason == :shutdown or
                (is_tuple(reason) and elem(reason, 0) == :shutdown)) ->
        {:noreply, disconnect(state, id)}

      {:participant, id} ->
        remove(state, id, :left)

      {:worker, id} ->
        {:noreply, state |> worker_down(id, reason) |> reconcile()}

      # Started again by the reconciler, with backoff.
      {:outlet, name} ->
        Logger.warning("Octoroom outlet #{name} stopped: #{inspect(reason)}")
        {outlet, outlets} = Map.pop(state.outlets, name)
        close_at_peer(state, outlet.worker_id, {:output, name})
        state = fail(%{state | outlets: outlets}, :media, [{{:outlet, name}, reason}])
        {:noreply, reconcile(state)}

      {:inlet, {worker_id, input} = key} ->
        Logger.warning("Octoroom inlet #{inspect(key)} stopped: #{inspect(reason)}")
        close_at_peer(state, worker_id, {:input, input})
        state = %{state | inlets: Map.delete(state.inlets, key)}
        {:noreply, reconcile(fail(state, :media, [{{:inlet, key}, reason}]))}

      {:peer, worker_id} ->
        {:noreply, state |> peer_down(worker_id, reason) |> reconcile()}

      nil ->
        {:noreply, state}
    end
  end

  # Exits are trapped for `terminate/2`; the parent's is handled by
  # GenServer, and nothing else is linked.
  # From a worker's `notify:` and `presence:` actions. Ignored from a
  # process that's no longer the worker's, such as one that was restarted.
  def handle_info({:octoroom_worker, pid, id, message}, state) do
    case state.workers[id] do
      %{pid: ^pid} -> {:noreply, worker_message(state, id, message)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # Workers' peers stop with the room's media supervisor; their Cloudflare
  # sessions end with their peer connections.
  @impl true
  def terminate(reason, state) do
    :telemetry.execute([:octoroom, :room, :stop], %{}, %{room_id: state.id, reason: reason})

    # The last participant left: nothing to recover. Otherwise (a crash, a
    # shutdown) the record stays so the next run recovers the room.
    if reason == :normal do
      Store.delete(state.store, :rooms, state.id)
      Worker.forget_room(state.store, state.id)
    end
  end

  ## Results of Cloudflare calls

  defp handle_result(state, p, :publish, {:ok, session, answer}) do
    reply(p, p.publish_tag, {:ok, %{sdp: answer}})

    tracks =
      Map.new(p.publishing, fn {source, mid} ->
        {source, %{status: :pending, mid: mid, muted: false}}
      end)

    p = %{
      p
      | session_id: session,
        media: :pending,
        publish_tag: nil,
        publishing: %{},
        tracks: tracks,
        timeline: Map.put(p.timeline, :published, now_ms())
    }

    signal(p, :resume, resume_data(p))
    {:noreply, put_p(state, p)}
  end

  defp handle_result(state, %{media: :adopting} = p, :adopt, {:ok, %{tracks: tracks}}) do
    published =
      for %{location: :local, mid: mid} = t <- tracks,
          {id, source} <- [Track.parse(t.track_name)],
          id == p.id,
          into: %{},
          do: {source, %{status: :live, mid: mid, muted: false}}

    case published do
      empty when empty == %{} ->
        republish(state, p, :nothing_published)

      _ ->
        remote = for %{location: :remote, mid: mid} = t <- tracks, mid != nil, do: t

        subs =
          Map.new(remote, fn t ->
            {name, stale} = adopted_name(t.track_name)
            {name, %{status: :open, gain: 1.0, mid: t.mid, stale: stale}}
          end)

        # Pulls of tracks whose owners haven't resumed yet are held during the
        # grace period, so nobody hears a gap while everyone comes back.
        ghosts =
          if state.recovering do
            for t <- remote,
                {name, false} <- [adopted_name(t.track_name)],
                t.status == :active,
                owner_id(name) != nil,
                not Map.has_key?(state.participants, owner_id(name)),
                into: state.ghosts,
                do: {name, %{session_id: t.session_id, track_name: t.track_name}}
          else
            state.ghosts
          end

        p = %{p | media: :live, tracks: published, subs: subs}
        own = for {source, _} <- published, do: track_name(p.id, source)
        state = %{state | ghosts: Map.drop(ghosts, own)}
        state = put_p(state, p)

        signal(p, :tracks, %{
          reset: true,
          added: track_infos(state, p, Map.keys(subs)),
          removed: []
        })

        event(state, {:published, public(p)})
        subscriptions_event(state, p)
        {:noreply, reconcile(state)}
    end
  end

  defp handle_result(state, %{media: :adopting} = p, :adopt, {:error, :disconnected}),
    do: republish(state, p, :disconnected)

  defp handle_result(state, %{media: :adopting} = p, :adopt, {:error, reason}),
    do: kick(state, p, {:resume_failed, reason})

  defp handle_result(state, p, :publish, {:error, reason}) do
    Logger.warning("Octoroom publish failed for #{p.id}: #{inspect(reason)}")
    reply(p, p.publish_tag, {:error, reason})
    {:noreply, put_p(state, %{p | media: :none, publish_tag: nil, publishing: %{}})}
  end

  defp handle_result(state, %{op: %{id: op_id} = op} = p, {:pushed, op_id}, result) do
    case result do
      {:ok, %{sdp: answer}} ->
        reply(p, op.tag, {:ok, %{sdp: answer}})
        reply(p, op.request_tag, {:ok, %{}})

        tracks =
          Enum.reduce(op.mids, p.tracks, fn {source, mid}, tracks ->
            Map.put(tracks, source, %{status: :pending, mid: mid, muted: false})
          end)

        # Live once the browser says it's flowing (`connected`).
        {:noreply, state |> put_p(%{p | tracks: tracks, op: nil}) |> reconcile()}

      {:error, reason} ->
        Logger.warning("Octoroom push for #{p.id} failed: #{inspect(reason)}")
        reply(p, op.tag, {:error, reason})
        reply(p, op.request_tag, {:error, reason})
        {:noreply, state |> put_p(%{p | op: nil}) |> reconcile()}
    end
  end

  defp handle_result(state, %{op: %{id: op_id} = op} = p, {:pulled, op_id}, result) do
    case result do
      {:ok, %{tracks: pulled} = resp} ->
        by_source =
          Map.new(op.sources, fn {name, src} -> {{src.session_id, src.track_name}, name} end)

        {added, failed} =
          Enum.reduce(pulled, {%{}, []}, fn t, {added, failed} ->
            name = by_source[{t.session_id, t.track_name}]

            cond do
              name == nil -> {added, failed}
              Map.has_key?(t, :error) -> {added, [{name, t.error} | failed]}
              true -> {Map.put(added, name, t.mid), failed}
            end
          end)

        # Requested tracks Cloudflare didn't mention count as failed.
        missing =
          for {name, _} <- op.sources,
              not Map.has_key?(added, name),
              not List.keymember?(failed, name, 0),
              do: {name, :missing}

        failed = failed ++ missing

        subs =
          Enum.reduce(added, p.subs, fn {name, mid}, subs -> put_in(subs[name].mid, mid) end)
          |> Map.drop(Enum.map(failed, &elem(&1, 0)))

        state = fail(state, p.id, failed)
        p = %{p | subs: subs, op: %{op | names: Map.keys(added)}}

        cond do
          added == %{} ->
            {:noreply, state |> put_p(%{p | op: nil}) |> reconcile()}

          resp.renegotiate and is_binary(resp.sdp) ->
            timer = timeout(state, p.id, op_id)
            request = {:renegotiate, %{op_id: op_id, sdp: resp.sdp}}
            signal(p, elem(request, 0), elem(request, 1))
            op = %{p.op | stage: :awaiting_answer, timer: timer, request: request}
            {:noreply, put_p(state, %{p | op: op})}

          true ->
            {:noreply, finish_pull(state, p)}
        end

      {:error, reason} ->
        Logger.warning("Octoroom pull for #{p.id} failed: #{inspect(reason)}")
        state = fail(state, p.id, Enum.map(op.sources, fn {name, _} -> {name, reason} end))
        p = %{p | subs: Map.drop(p.subs, Map.keys(op.sources)), op: nil}
        {:noreply, state |> put_p(p) |> reconcile()}
    end
  end

  defp handle_result(state, %{op: %{id: op_id}} = p, {:renegotiated, op_id}, result) do
    case result do
      :ok ->
        reply(p, p.op.tag, {:ok, %{}})
        {:noreply, finish_pull(state, p)}

      {:error, reason} ->
        reply(p, p.op.tag, {:error, reason})
        kick(state, p, {:renegotiate_failed, reason})
    end
  end

  defp handle_result(state, %{op: %{id: op_id} = op} = p, {:closed, op_id}, result) do
    case result do
      {:ok, %{sdp: answer}} ->
        reply(p, op.tag, {:ok, %{sdp: answer}})
        reply(p, op.request_tag, {:ok, %{}})
        if op.names != [], do: signal(p, :tracks, %{added: [], removed: op.mids})
        tracks = Map.drop(p.tracks, op.local)
        p = %{p | subs: Map.drop(p.subs, op.names), tracks: tracks, op: nil}
        state = put_p(state, p)
        if op.names != [], do: subscriptions_event(state, p)
        {:noreply, reconcile(state)}

      {:error, reason} ->
        reply(p, op.tag, {:error, reason})
        reply(p, op.request_tag, {:error, reason})
        kick(state, p, {:close_failed, reason})
    end
  end

  # A result for an operation that was superseded (the participant was
  # kicked and rejoined, or a timeout fired).
  defp handle_result(state, _p, _kind, _result), do: {:noreply, state}

  defp finish_pull(state, %{op: op} = p) do
    :telemetry.execute(
      [:octoroom, :pull, :stop],
      %{duration_ms: System.monotonic_time(:millisecond) - op.started, tracks: length(op.names)},
      %{room_id: state.id, participant_id: p.id}
    )

    p = first_pull_telemetry(state, p, length(op.names))

    added = track_infos(state, p, op.names)
    signal(p, :tracks, %{added: added, removed: []})
    subs = Enum.reduce(op.names, p.subs, fn name, subs -> put_in(subs[name].status, :open) end)
    failures = Map.drop(state.failures, Enum.map(op.names, &{p.id, &1}))
    p = %{p | subs: subs, op: nil}
    state = put_p(%{state | failures: failures}, p)
    subscriptions_event(state, p)
    reconcile(state)
  end

  ## Reconcile

  # A policy callback that fails keeps its last good answer: the room keeps
  # its workers, or a listener its subscriptions (other listeners still
  # reconcile). Tracks that leave the directory still close.
  defp reconcile(state) do
    room = room(state)

    {specs, errors} =
      case call_room(fn -> state.module.workers(room) end, &worker_specs?/1, "worker specs") do
        {:ok, specs} ->
          {specs |> Enum.uniq_by(& &1.id) |> Enum.map(&Map.put_new(&1, :data, [])), %{}}

        {:error, error} ->
          {state.worker_specs, %{workers: error}}
      end

    state = reconcile_workers(%{state | worker_specs: specs})
    room = room(state)
    data_names = data_outputs(state)

    # Subscriptions to data outputs carry no media, so they apply to every
    # participant, live or not; the rest wait for its media to be live.
    # With no data outputs in the room, only live participants are asked.
    {desired, data_subs, errors} =
      for p <- participants(state),
          p.media == :live or data_names != %{},
          reduce: {%{}, %{}, errors} do
        {desired, data_subs, errors} ->
          listener = public(p)
          subscriptions = fn -> state.module.subscriptions(listener, room) end

          case call_room(subscriptions, &subscriptions?/1, "tracks or track names") do
            {:ok, wanted} ->
              {data, media} = Enum.split_with(wanted, &Map.has_key?(data_names, track_name(&1)))
              data = MapSet.new(data, &track_name/1)

              desired =
                if p.media == :live,
                  do: Map.put(desired, p.id, media ++ held_ghosts(state, p, media)),
                  else: desired

              {desired, Map.put(data_subs, p.id, data), errors}

            {:error, error} ->
              desired = if p.media == :live, do: Map.put(desired, p.id, holding(p)), else: desired
              {desired, data_subs, Map.put(errors, {:subscriptions, p.id}, error)}
          end
      end

    state = report_policy_errors(state, errors)

    # A participant whose policy failed keeps what it had, less data outputs
    # that are gone.
    state =
      Enum.reduce(state.participants, state, fn {id, p}, state ->
        data =
          Map.get_lazy(data_subs, id, fn ->
            MapSet.filter(p.data_subs, &Map.has_key?(data_names, &1))
          end)

        if data == p.data_subs, do: state, else: put_p(state, %{p | data_subs: data})
      end)

    actual = %{
      subscriptions: Map.new(state.participants, fn {id, p} -> {id, p.subs} end),
      tracks: directory(state)
    }

    ops = Reconciler.diff(desired, actual) |> Enum.group_by(&elem(&1, 1))
    requesting = for {id, %{requests: [_ | _]}} <- state.participants, do: id

    state =
      (Map.keys(ops) ++ requesting)
      |> Enum.uniq()
      |> Enum.reduce(state, fn id, state ->
        apply_ops(state, state.participants[id], Map.get(ops, id, []))
      end)

    state |> sync_seen() |> schedule_retry()
  end

  defp apply_ops(state, p, ops) do
    # Gain changes are client-side only, so they don't wait for the queue.
    p =
      Enum.reduce(ops, p, fn
        {:update_subscription, _, name, %{gain: gain}}, p ->
          signal(p, :gain, %{mid: p.subs[name].mid, gain: gain})
          put_in(p.subs[name].gain, gain)

        _, p ->
          p
      end)

    closes = for {:close_subscription, _, name} <- ops, do: name

    opens =
      for {:open_subscription, _, name, opts} <- ops,
          may_retry?(state, p.id, name),
          do: {name, opts}

    request = ready_request(state, p)

    cond do
      p.op != nil -> put_p(state, p)
      request != nil -> start_request(state, p, request)
      closes != [] -> start_close(state, p, closes)
      opens != [] -> start_pull(state, p, opens)
      true -> put_p(state, p)
    end
  end

  # The participant's oldest publish or unpublish, once it can start. An
  # unpublish waits for everyone's pulls of the track to close first.
  defp ready_request(_state, %{media: media}) when media != :live, do: nil
  defp ready_request(_state, %{requests: []}), do: nil

  defp ready_request(state, %{requests: [{:unpush, source, _} = request | _]} = p) do
    name = track_name(p.id, source)
    pulled = Enum.any?(state.participants, fn {_, other} -> Map.has_key?(other.subs, name) end)
    if not pulled, do: request
  end

  defp ready_request(_state, %{requests: [request | _]}), do: request

  defp start_request(state, p, {:push, sources, tag} = request) do
    op_id = new_id()
    timer = timeout(state, p.id, op_id)
    signal_request = {:push, %{op_id: op_id, sources: sources}}
    signal(p, elem(signal_request, 0), elem(signal_request, 1))

    op = %{
      id: op_id,
      kind: :push,
      stage: :awaiting_push_offer,
      sources: sources,
      mids: %{},
      tag: nil,
      request_tag: tag,
      timer: timer,
      request: signal_request
    }

    put_p(state, %{p | requests: List.delete(p.requests, request), op: op})
  end

  defp start_request(state, p, {:unpush, source, tag} = request) do
    p = %{p | requests: List.delete(p.requests, request)}

    case p.tracks[source] do
      %{mid: mid} ->
        start_close(state, p, [], local: [source], mids: [mid], request_tag: tag)

      nil ->
        reply(p, tag, {:ok, %{}})
        put_p(state, p)
    end
  end

  defp start_pull(state, p, opens) do
    op_id = new_id()
    dir = sessions(state)
    sources = Map.new(opens, fn {name, _} -> {name, dir[name]} end)

    subs =
      Enum.reduce(opens, p.subs, fn {name, opts}, subs ->
        Map.put(subs, name, %{status: :opening, gain: opts.gain, mid: nil})
      end)

    cf = state.cloudflare
    session = p.session_id

    run(state, p.id, {:pulled, op_id}, fn ->
      Cloudflare.pull_tracks(cf, session, Map.values(sources))
    end)

    op = %{
      id: op_id,
      kind: :pull,
      stage: :pulling,
      sources: sources,
      names: [],
      tag: nil,
      timer: nil,
      request: nil,
      started: System.monotonic_time(:millisecond)
    }

    put_p(state, %{p | subs: subs, op: op})
  end

  # Closes pulls (`names`) or, with `local:`, the participant's own tracks.
  defp start_close(state, p, names, opts \\ []) do
    op_id = new_id()
    mids = Keyword.get_lazy(opts, :mids, fn -> Enum.map(names, &p.subs[&1].mid) end)
    subs = Enum.reduce(names, p.subs, fn name, subs -> put_in(subs[name].status, :closing) end)
    timer = timeout(state, p.id, op_id)
    request = {:close, %{op_id: op_id, mids: mids}}
    signal(p, elem(request, 0), elem(request, 1))

    op = %{
      id: op_id,
      kind: :close,
      stage: :awaiting_offer,
      names: names,
      local: Keyword.get(opts, :local, []),
      mids: mids,
      tag: nil,
      request_tag: Keyword.get(opts, :request_tag),
      timer: timer,
      request: request
    }

    put_p(state, %{p | subs: subs, op: op})
  end

  defp fail(state, _id, []), do: state

  # Each failure backs off (0.5 s, 1 s, 2 s, ...) and is given up after
  # @max_failures. Keys are `{participant_id, track}` for pulls (cleared
  # when the track is published again), `{:worker, id}` for workers that
  # failed to start or crashed, and `{:media, {:outlet | :inlet | :peer, key}}`
  # for media that failed (a pull Cloudflare refused, a peer that stopped).
  defp fail(state, id, failed) do
    now = System.monotonic_time(:millisecond)

    failures =
      Enum.reduce(failed, state.failures, fn {name, reason}, acc ->
        Logger.info("Octoroom #{inspect(id)} #{inspect(name)} failed: #{inspect(reason)}")
        count = Map.get(acc, {id, name}, %{count: 0}).count + 1

        if count == @max_failures do
          what =
            case id do
              :worker -> {:worker, name}
              :media -> name
              participant -> {:pull, participant, name}
            end

          Logger.warning("Octoroom gave up on #{inspect(what)}: #{inspect(reason)}")
          Octoroom.broadcast(state.id, {:error, what, reason})
        end

        :telemetry.execute([:octoroom, :failure], %{count: count}, %{
          room_id: state.id,
          id: id,
          name: name,
          reason: reason,
          given_up: count >= @max_failures
        })

        Map.put(acc, {id, name}, %{
          count: count,
          at: now + state.retry_base_ms * Integer.pow(2, count)
        })
      end)

    %{state | failures: failures}
  end

  defp may_retry?(state, id, name) do
    case state.failures[{id, name}] do
      nil -> true
      %{count: n, at: at} -> n < @max_failures and System.monotonic_time(:millisecond) >= at
    end
  end

  defp schedule_retry(%{retry: nil} = state) do
    retry_at = for {_, %{count: n, at: at}} <- state.failures, n < @max_failures, do: at

    if retry_at == [] do
      state
    else
      delay = max(Enum.min(retry_at) - System.monotonic_time(:millisecond), 0)
      %{state | retry: Process.send_after(self(), :retry, delay)}
    end
  end

  defp schedule_retry(state), do: state

  ## The room module's callbacks

  # Calls into the room module (or the function given to `update_meta/3`).
  # A raise, throw or exit, or a result that isn't `expected`, is a bug in
  # the app, and acting on it or crashing the room would be worse than
  # keeping the last good answer: a room that crashed would recover into the
  # same failure. Returns `{:ok, result}` or `{:error, {reason, formatted}}`,
  # where `reason` is the exception, `{:throw, value}`, `{:exit, reason}` or
  # `{:bad_return, value}`, and `formatted` is for the log.
  defp call_room(fun, valid?, expected) do
    result = fun.()

    if valid?.(result),
      do: {:ok, result},
      else: {:error, {{:bad_return, result}, "returned #{inspect(result)}, expected #{expected}"}}
  catch
    kind, reason ->
      formatted = Exception.format(kind, reason, __STACKTRACE__)

      case kind do
        :error -> {:error, {Exception.normalize(:error, reason, __STACKTRACE__), formatted}}
        kind -> {:error, {{kind, reason}, formatted}}
      end
  end

  defp worker_specs?(specs), do: is_list(specs) and Enum.all?(specs, &worker_spec?/1)

  # `data` is optional, for specs built by hand rather than with `worker/3`.
  defp worker_spec?(%{id: id, module: module, inputs: inputs, outputs: outputs, args: _} = spec)
       when is_binary(id) and is_atom(module) and is_list(inputs) and is_list(outputs) do
    data = Map.get(spec, :data, [])
    is_list(data) and Enum.all?(inputs ++ outputs ++ data, &is_binary/1)
  end

  defp worker_spec?(_spec), do: false

  defp subscriptions?(wanted) do
    is_list(wanted) and
      Enum.all?(wanted, fn
        %Track{name: name, gain: gain} -> is_binary(name) and is_number(gain)
        name -> is_binary(name)
      end)
  end

  ## Worker presence and events

  defp worker_message(state, id, {:notify, output, type, data, to}) do
    viewers =
      for {pid, outputs} <- state.seen,
          Map.get(outputs, output) == id,
          to == nil or pid == to,
          do: pid

    payload = %{worker: id, output: output, type: type, data: data}
    for pid <- viewers, do: signal(state.participants[pid], :worker_event, payload)

    event = {:worker_notify, id, output, type, data}
    Octoroom.deliver(state.id, viewers, event)
    if to == nil, do: Octoroom.broadcast(state.id, event)
    state
  end

  defp worker_message(state, id, {:presence, status, attributes}) do
    presence = %{state: status, attributes: attributes}

    if state.presence[id] == presence,
      do: state,
      else: presence_changed(put_in(state.presence[id], presence), id)
  end

  # A worker (re)started: its state is unknown until it sets it again.
  defp restarted_presence(state, id) do
    case state.presence[id] do
      %{state: nil} -> state
      nil -> state
      presence -> presence_changed(put_in(state.presence[id], %{presence | state: nil}), id)
    end
  end

  defp presence_changed(state, id) do
    payload = worker_presence(state, id)
    viewers = for {pid, outputs} <- state.seen, id in Map.values(outputs), do: pid

    for pid <- viewers,
        do: signal(state.participants[pid], :worker, %{op: :updated, worker: payload})

    Octoroom.deliver(state.id, viewers, {:worker, :updated, payload})
    Octoroom.broadcast(state.id, {:worker, :updated, payload})
    state
  end

  # What clients are told about a worker.
  defp worker_presence(state, id) do
    spec = Enum.find(state.worker_specs, &(&1.id == id)) || %{outputs: [], data: []}
    presence = Map.get(state.presence, id, %{state: nil, attributes: %{}})

    %{
      id: id,
      outputs: spec.outputs,
      data: Map.get(spec, :data, []),
      state: presence.state,
      attributes: presence.attributes
    }
  end

  # Output name => worker id, for every worker output, audio or data.
  defp worker_outputs(state) do
    audio =
      for spec <- Enum.reverse(state.worker_specs),
          name <- spec.outputs,
          into: %{},
          do: {name, spec.id}

    Map.merge(audio, data_outputs(state))
  end

  # Who receives which worker outputs, against the last pass: workers hear
  # about participants subscribing and unsubscribing, and clients about
  # workers they can now see or no longer see. Presence of workers that
  # are gone is dropped.
  defp sync_seen(state) do
    owners = worker_outputs(state)

    now =
      Map.new(state.participants, fn {pid, p} ->
        audio = for {name, %{status: :open}} <- p.subs, Map.has_key?(owners, name), do: name
        data = Enum.filter(p.data_subs, &Map.has_key?(owners, &1))
        {pid, Map.new(audio ++ data, &{&1, owners[&1]})}
      end)

    for pid <- Enum.uniq(Map.keys(state.seen) ++ Map.keys(now)) do
      before = Map.get(state.seen, pid, %{})
      after_ = Map.get(now, pid, %{})

      for {name, wid} <- before,
          after_[name] != wid,
          %{pid: worker} <- [state.workers[wid]],
          do: send(worker, {:octoroom, :unsubscribed, pid, name})

      for {name, wid} <- after_,
          before[name] != wid,
          %{pid: worker} <- [state.workers[wid]],
          do: send(worker, {:octoroom, :subscribed, pid, name})

      # A participant that left isn't told anything.
      if p = state.participants[pid] do
        was = before |> Map.values() |> MapSet.new()
        is = after_ |> Map.values() |> MapSet.new()

        for wid <- MapSet.difference(is, was) |> Enum.sort() do
          payload = worker_presence(state, wid)
          signal(p, :worker, %{op: :added, worker: payload})
          Octoroom.deliver(state.id, [pid], {:worker, :added, payload})
        end

        for wid <- MapSet.difference(was, is) |> Enum.sort() do
          signal(p, :worker, %{op: :removed, worker: %{id: wid}})
          Octoroom.deliver(state.id, [pid], {:worker, :removed, %{id: wid}})
        end
      end
    end

    specs = MapSet.new(state.worker_specs, & &1.id)
    %{state | seen: now, presence: Map.filter(state.presence, fn {id, _} -> id in specs end)}
  end

  # The workers participant `pid` sees, as clients are told about them.
  defp seen_workers(state, pid) do
    state.seen
    |> Map.get(pid, %{})
    |> Map.values()
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&worker_presence(state, &1))
  end

  # Data output name => the id of the worker it belongs to. If two workers
  # name the same one, the first in the specs has it, as with outputs.
  defp data_outputs(state) do
    for spec <- Enum.reverse(state.worker_specs),
        name <- Map.get(spec, :data, []),
        into: %{},
        do: {name, spec.id}
  end

  defp track_name(%Track{name: name}), do: name
  defp track_name(name) when is_binary(name), do: name

  # What `p` holds now, at the gains it has, so the diff leaves it alone.
  defp holding(p), do: for({name, sub} <- p.subs, do: %{Track.new(name) | gain: sub.gain})

  # Reconcile runs on every room change, so a failing callback is reported
  # when it starts failing or fails differently, not on every pass.
  defp report_policy_errors(state, errors) do
    for {what, {reason, _} = error} <- errors,
        state.policy_errors[what] != reason,
        do: policy_failed(state, what, error)

    %{state | policy_errors: Map.new(errors, fn {what, {reason, _}} -> {what, reason} end)}
  end

  defp policy_failed(state, what, {reason, formatted}) do
    module = inspect(state.module)

    {callback, participant_id, message} =
      case what do
        :mount ->
          {:mount, nil, "#{module}.mount/1 failed, so the room didn't start"}

        :workers ->
          {:workers, nil, "#{module}.workers/1 failed, so the room keeps its workers as they are"}

        {:subscriptions, id} ->
          {:subscriptions, id,
           "#{module}.subscriptions/2 failed for #{id}, so its subscriptions stay as they are"}

        {:update_meta, id} ->
          {:update_meta, id,
           "the function given to update_meta/3 failed for #{id}, so its metadata is unchanged"}
      end

    Logger.error("Octoroom room #{state.id}: #{message}:\n" <> formatted)
    Octoroom.broadcast(state.id, {:error, {:policy, callback}, reason})

    :telemetry.execute([:octoroom, :policy, :error], %{}, %{
      room_id: state.id,
      callback: callback,
      participant_id: participant_id,
      reason: reason
    })
  end

  ## Workers

  defp reconcile_workers(state) do
    actual = %{
      workers: Map.new(state.workers, fn {id, w} -> {id, w.spec} end),
      outlets: Map.new(state.outlets, fn {name, o} -> {name, o.worker_id} end),
      inlets: Map.keys(state.inlets),
      tracks: directory(state)
    }

    # Tracks to close at their peers, sent once it's known which peers stay:
    # a peer that stops ends its whole session.
    state =
      state.worker_specs
      |> Reconciler.diff_workers(actual)
      |> Enum.reduce(Map.put(state, :closes, []), &apply_worker_op/2)

    {closes, state} = Map.pop(stop_idle_peers(state), :closes)
    for {worker_id, ref} <- Enum.reverse(closes), do: close_at_peer(state, worker_id, ref)
    state
  end

  defp apply_worker_op({:stop_inlet, {worker_id, input} = key}, state) do
    {inlet, inlets} = Map.pop(state.inlets, key)
    stop_child(state, :media, inlet)
    %{state | inlets: inlets, closes: [{worker_id, {:input, input}} | state.closes]}
  end

  defp apply_worker_op({:stop_outlet, name}, state) do
    {outlet, outlets} = Map.pop(state.outlets, name)
    stop_child(state, :media, outlet)
    %{state | outlets: outlets, closes: [{outlet.worker_id, {:output, name}} | state.closes]}
  end

  # The room no longer wants it: what it saved goes too. A restart (below)
  # keeps it.
  defp apply_worker_op({:stop_worker, id}, state) do
    state = stop_worker(state, id)
    Worker.forget(state.store, state.id, id)
    state
  end

  defp apply_worker_op({:start_worker, spec}, state), do: start_worker(state, spec)

  defp apply_worker_op({:restart_worker, spec}, state),
    do: state |> stop_worker(spec.id) |> start_worker(spec)

  defp apply_worker_op({:update_worker, spec}, state) do
    w = state.workers[spec.id]
    send(w.pid, {:octoroom_io, spec.inputs, spec.outputs, Map.get(spec, :data, [])})
    put_in(state.workers[spec.id].spec, spec)
  end

  defp apply_worker_op({:start_outlet, name, worker_id}, state) do
    with true <- may_retry?(state, :media, {:outlet, name}),
         {:ok, peer, state} <- ensure_peer(state, worker_id) do
      opts = %{room_id: state.id, name: name, server: self()}

      case start_child(state, :media, {Outlet, opts}) do
        {:ok, pid} ->
          # Track names are unique per Cloudflare session, and a worker's
          # outputs have distinct names.
          cf_track = "out-" <> Base.url_encode64(name, padding: false)
          Peer.push(peer, name, cf_track, pid)

          outlet = %{
            pid: pid,
            monitor: Process.monitor(pid),
            worker_id: worker_id,
            cf_track: cf_track,
            session_id: nil,
            status: :creating,
            live_seen: false,
            started: now_ms()
          }

          put_in(state.outlets[name], outlet)

        {:error, reason} ->
          fail(state, :media, [{{:outlet, name}, reason}])
      end
    else
      false -> state
      {:error, state} -> state
    end
  end

  defp apply_worker_op({:start_inlet, {worker_id, input} = key}, state) do
    source = sessions(state)[input]

    with true <- Map.has_key?(state.workers, worker_id) and source != nil,
         true <- may_retry?(state, :media, {:inlet, key}),
         {:ok, peer, state} <- ensure_peer(state, worker_id) do
      opts = %{
        room_id: state.id,
        worker_id: worker_id,
        input: input,
        format: state.workers[worker_id].spec.module.__octoroom_audio__()
      }

      case start_child(state, :media, {Inlet, opts}) do
        {:ok, pid} ->
          Peer.pull(peer, input, source, pid)
          inlet = %{pid: pid, monitor: Process.monitor(pid), status: :pulling}
          put_in(state.inlets[key], inlet)

        {:error, reason} ->
          fail(state, :media, [{{:inlet, key}, reason}])
      end
    else
      false -> state
      {:error, state} -> state
    end
  end

  defp ensure_peer(state, worker_id) do
    case state.peers[worker_id] do
      %{pid: pid} ->
        {:ok, pid, state}

      nil ->
        opts = %{
          room_id: state.id,
          worker_id: worker_id,
          server: self(),
          cloudflare: state.cloudflare,
          media: state.peer_media
        }

        with true <- may_retry?(state, :media, {:peer, worker_id}),
             {:ok, pid} <- start_child(state, :media, {Peer, opts}) do
          peer = %{pid: pid, monitor: Process.monitor(pid)}
          {:ok, pid, put_in(state.peers[worker_id], peer)}
        else
          false -> {:error, state}
          {:error, reason} -> {:error, fail(state, :media, [{{:peer, worker_id}, reason}])}
        end
    end
  end

  # A worker with no inlets or outlets left doesn't need its peer. Stopping
  # it closes its peer connection, which ends its Cloudflare session.
  defp stop_idle_peers(state) do
    busy =
      MapSet.new(
        Enum.map(state.outlets, fn {_, o} -> o.worker_id end) ++
          Enum.map(state.inlets, fn {{worker_id, _}, _} -> worker_id end)
      )

    {idle, peers} = Map.split_with(state.peers, fn {id, _} -> not MapSet.member?(busy, id) end)
    for {_, peer} <- idle, do: stop_child(state, :media, peer)
    %{state | peers: peers}
  end

  defp close_at_peer(state, worker_id, ref) do
    case state.peers[worker_id] do
      %{pid: pid} -> Peer.close(pid, ref)
      nil -> :ok
    end
  end

  # A peer that connects has shown its worker's media works: earlier
  # failures stop counting toward giving up.
  defp peer_result(state, worker_id, :connected),
    do: %{state | failures: Map.delete(state.failures, {:media, {:peer, worker_id}})}

  defp peer_result(state, worker_id, {:pushed, name, session_id}) do
    case state.outlets[name] do
      %{worker_id: ^worker_id, status: :creating} = o ->
        status = if o.live_seen, do: :live, else: :pending
        if status == :live, do: output_live(state, name, o)
        failures = Map.delete(state.failures, {:media, {:outlet, name}})
        o = %{o | session_id: session_id, status: status}
        %{state | failures: failures, outlets: Map.put(state.outlets, name, o)}

      _ ->
        state
    end
  end

  defp peer_result(state, worker_id, {:pulled, input}) do
    key = {worker_id, input}

    case state.inlets[key] do
      %{} = i ->
        failures = Map.delete(state.failures, {:media, {:inlet, key}})

        %{
          state
          | failures: failures,
            inlets: Map.put(state.inlets, key, %{i | status: :connected})
        }

      nil ->
        state
    end
  end

  # Pulls of a track with no packets yet fail (`empty_track_error`); the
  # inlet goes, and the reconciler starts it again after a backoff.
  defp peer_result(state, worker_id, {:pull_failed, input, reason}) do
    key = {worker_id, input}

    case Map.pop(state.inlets, key) do
      {nil, _} ->
        state

      {inlet, inlets} ->
        stop_child(state, :media, inlet)
        fail(%{state | inlets: inlets}, :media, [{{:inlet, key}, reason}])
    end
  end

  # A peer that stopped takes its worker's media with it: the outlets and
  # inlets go, listeners' pulls of its outputs close, and the reconciler
  # starts it all again (with backoff, if it failed).
  defp peer_down(state, worker_id, reason) do
    Logger.warning("Octoroom peer of worker #{worker_id} stopped: #{inspect(reason)}")
    {_, peers} = Map.pop(state.peers, worker_id)

    {gone_outlets, outlets} =
      Map.split_with(state.outlets, fn {_, o} -> o.worker_id == worker_id end)

    {gone_inlets, inlets} = Map.split_with(state.inlets, fn {{id, _}, _} -> id == worker_id end)

    for {_, media} <- Map.to_list(gone_outlets) ++ Map.to_list(gone_inlets),
        do: stop_child(state, :media, media)

    state = %{state | peers: peers, outlets: outlets, inlets: inlets}

    if reason in [:normal, :shutdown],
      do: state,
      else: fail(state, :media, [{{:peer, worker_id}, reason}])
  end

  defp start_worker(state, spec) do
    if may_retry?(state, :worker, spec.id) do
      opts = %{
        room_id: state.id,
        server: self(),
        spec: spec,
        participants: Enum.map(participants(state), &public/1),
        resumed: state.recovering,
        store: state.store
      }

      case start_child(state, :workers, {Worker.Server, opts}) do
        {:ok, pid} ->
          w = %{
            spec: spec,
            pid: pid,
            monitor: Process.monitor(pid),
            started: System.monotonic_time(:millisecond)
          }

          :telemetry.execute([:octoroom, :worker, :start], %{}, %{
            room_id: state.id,
            id: spec.id,
            module: spec.module,
            resumed: state.recovering != nil
          })

          # Inlets outlive a restart; a new module may hear in another format.
          format = spec.module.__octoroom_audio__()

          for {{id, _input}, %{pid: inlet}} <- state.inlets,
              id == spec.id,
              do: send(inlet, {:octoroom_format, format})

          # A restart: whoever already sees it is subscribed to the new
          # process too, and its state starts over.
          for {participant_id, outputs} <- state.seen,
              {name, worker_id} <- outputs,
              worker_id == spec.id,
              do: send(pid, {:octoroom, :subscribed, participant_id, name})

          state = put_in(state.workers[spec.id], w)
          restarted_presence(state, spec.id)

        {:error, reason} ->
          Logger.warning("Octoroom couldn't start worker #{spec.id}: #{inspect(reason)}")
          fail(state, :worker, [{spec.id, reason}])
      end
    else
      state
    end
  end

  defp stop_worker(state, id) do
    case Map.pop(state.workers, id) do
      {nil, _} ->
        state

      {w, workers} ->
        stop_child(state, :workers, w)
        failures = Map.delete(state.failures, {:worker, id})
        %{state | workers: workers, failures: failures}
    end
  end

  # A worker the room didn't stop. The reconciler starts it again, with
  # backoff; its inlets and outlets stay, so its tracks stay published.
  defp worker_down(state, id, reason) do
    {w, workers} = Map.pop(state.workers, id)
    Logger.warning("Octoroom worker #{id} exited: #{inspect(reason)}")
    Octoroom.broadcast(state.id, {:worker_down, id, reason})

    :telemetry.execute([:octoroom, :worker, :exit], %{}, %{
      room_id: state.id,
      id: id,
      reason: reason
    })

    ran = System.monotonic_time(:millisecond) - w.started

    failures =
      if ran > @worker_stable_ms,
        do: Map.delete(state.failures, {:worker, id}),
        else: state.failures

    fail(%{state | workers: workers, failures: failures}, :worker, [{id, reason}])
  end

  defp put_room_record(state) do
    Store.put(state.store, :rooms, state.id, %{
      run: state.run,
      assigns: state.assigns,
      updated_at: Store.now()
    })
  end

  defp start_child(state, sup, spec) do
    DynamicSupervisor.start_child(sup_name(state, sup), spec)
  catch
    :exit, reason -> {:error, {:supervisor_down, reason}}
  end

  defp stop_child(state, sup, %{pid: pid, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    DynamicSupervisor.terminate_child(sup_name(state, sup), pid)
  catch
    :exit, _ -> :ok
  end

  defp inlet_dropped(pid) do
    Inlet.stats(pid).dropped
  catch
    :exit, _ -> 0
  end

  defp sup_name(state, :media), do: Room.Supervisor.media(state.id)
  defp sup_name(state, :workers), do: Room.Supervisor.workers(state.id)

  defp monitored(state, ref) do
    find = fn map, kind ->
      Enum.find_value(map, fn {key, v} -> if v.monitor == ref, do: {kind, key} end)
    end

    find.(state.participants, :participant) || find.(state.workers, :worker) ||
      find.(state.outlets, :outlet) || find.(state.inlets, :inlet) || find.(state.peers, :peer)
  end

  ## Participants

  defp remove(state, id, reason) do
    case Map.pop(state.participants, id) do
      {nil, _} ->
        {:noreply, state}

      {p, participants} ->
        if p.monitor, do: Process.demonitor(p.monitor, [:flush])
        cancel(p.disconnected)
        if p.op, do: cancel(p.op.timer)
        if p.op, do: reply(p, Map.get(p.op, :request_tag), {:error, reason})
        if p.publish_tag, do: reply(p, p.publish_tag, {:error, reason})
        for {_, _, tag} <- p.requests, do: reply(p, tag, {:error, reason})

        state = %{
          state
          | participants: participants,
            order: List.delete(state.order, id),
            failures: Map.reject(state.failures, fn {{pid, _}, _} -> pid == id end)
        }

        event(state, {:left, public(p)})

        :telemetry.execute([:octoroom, :participant, :leave], %{}, %{
          room_id: state.id,
          id: id,
          reason: reason
        })

        if map_size(participants) == 0,
          do: {:stop, :normal, state},
          else: {:noreply, reconcile(state)}
    end
  end

  defp kick(state, p, reason) do
    Logger.warning("Octoroom removing #{p.id}: #{inspect(reason)}")
    signal(p, :kick, reason)
    remove(state, p.id, :kicked)
  end

  defp participants(state), do: Enum.map(state.order, &state.participants[&1])

  defp new_participant(id, meta, pid) do
    %{
      id: id,
      meta: meta,
      pid: pid,
      monitor: Process.monitor(pid),
      session_id: nil,
      # Its session: :none, :publishing (creating it), :adopting (after a
      # restart), :pending (published, not yet connected) or :live.
      media: :none,
      # Source => %{status: :pending | :live | :closing, mid, muted}.
      tracks: %{},
      # The sources of a first publish in flight: source => mid.
      publishing: %{},
      publish_tag: nil,
      # Publishes and unpublishes waiting for the session's queue.
      requests: [],
      subs: %{},
      # Names of the data outputs it's subscribed to (see `Room.worker/3`).
      data_subs: MapSet.new(),
      op: nil,
      # The grace timer while its connection is down.
      disconnected: nil,
      # When each step of its join happened (monotonic ms), for telemetry:
      # :joined, then :publish, :published, :connected and :first_pull as
      # they come. A publish on a new session starts again from :publish.
      timeline: %{joined: now_ms()}
    }
  end

  ## Join telemetry

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The first `connected` after a publish: the join is done, as far as the
  # participant's own media goes. Not for an adopted session, whose publish
  # happened in an earlier run.
  defp connected_telemetry(state, %{timeline: %{published: published} = t} = p, timings)
       when not is_map_key(t, :connected) do
    now = now_ms()

    server = %{
      duration_ms: now - t.joined,
      before_publish_ms: t.publish - t.joined,
      publish_ms: published - t.publish,
      connect_ms: now - published
    }

    {flags, client} = Map.split(timings, [:ice_timed_out])
    client = Map.new(client, fn {k, v} -> {:"client_#{k}", v} end)

    meta =
      Map.merge(flags, %{room_id: state.id, id: p.id, sources: Map.keys(p.tracks)})

    :telemetry.execute([:octoroom, :participant, :connected], Map.merge(client, server), meta)
    %{p | timeline: Map.put(t, :connected, now)}
  end

  defp connected_telemetry(_state, p, _timings), do: p

  # The first pull into a connected participant's session finished: from
  # here it hears someone.
  defp first_pull_telemetry(state, %{timeline: %{connected: connected} = t} = p, tracks)
       when not is_map_key(t, :first_pull) do
    now = now_ms()

    :telemetry.execute(
      [:octoroom, :participant, :first_pull],
      %{duration_ms: now - t.joined, since_connected_ms: now - connected, tracks: tracks},
      %{room_id: state.id, id: p.id}
    )

    %{p | timeline: Map.put(t, :first_pull, now)}
  end

  defp first_pull_telemetry(_state, p, _tracks), do: p

  defp output_live(state, name, outlet) do
    :telemetry.execute(
      [:octoroom, :outlet, :live],
      %{duration_ms: now_ms() - outlet.started},
      %{room_id: state.id, name: name, worker_id: outlet.worker_id}
    )

    Octoroom.broadcast(state.id, {:output_live, name})
  end

  defp add_participant(state, p) do
    state = %{
      state
      | participants: Map.put(state.participants, p.id, p),
        order: state.order ++ [p.id]
    }

    event(state, {:joined, public(p)}, except: p.id)
    state
  end

  defp join_reply(state, p, resumed) do
    %{
      participant_id: p.id,
      participants: Enum.map(participants(state), &public/1),
      ice_servers: Octoroom.ice_servers(),
      # The workers it sees; updates come as `worker` signals.
      workers: seen_workers(state, p.id),
      resumed: resumed,
      # The channel turns this into the client's resume token.
      resume: resume_data(p)
    }
  end

  defp resume_data(p),
    do: %{participant_id: p.id, session_id: p.session_id, meta: p.meta}

  defp disconnect(state, id) do
    p = state.participants[id]
    ref = make_ref()
    Process.send_after(self(), {:disconnect_expired, id, ref}, state.grace_ms)
    Octoroom.broadcast(state.id, {:disconnected, public(p)})
    put_p(state, %{p | pid: nil, monitor: nil, disconnected: ref})
  end

  # After a rejoin: the client may have missed signals while it was away, so
  # it gets the full list of what it hears, and any request still waiting on
  # it again.
  defp resync(state, p) do
    open = for {name, %{status: :open}} <- p.subs, do: name
    signal(p, :tracks, %{reset: true, added: track_infos(state, p, open), removed: []})

    case p.op do
      %{request: {kind, payload}, stage: stage} = op
      when stage in [:awaiting_answer, :awaiting_offer, :awaiting_push_offer] ->
        cancel(op.timer)
        signal(p, kind, payload)
        put_p(state, %{p | op: %{op | timer: timeout(state, p.id, op.id)}})

      _ ->
        state
    end
  end

  # Its Cloudflare session is gone (or published nothing): it publishes again
  # as if it had just joined.
  defp republish(state, p, reason) do
    Logger.info("Octoroom #{p.id} has to publish again: #{inspect(reason)}")
    # The client publishes everything again, so queued requests are moot.
    if p.op, do: reply(p, Map.get(p.op, :request_tag), {:error, :republishing})
    for {_, _, tag} <- p.requests, do: reply(p, tag, {:error, :republishing})

    p = %{
      p
      | media: :none,
        session_id: nil,
        tracks: %{},
        requests: [],
        subs: %{},
        op: nil
    }

    signal(p, :republish, %{reason: reason})
    signal(p, :resume, resume_data(p))
    {:noreply, state |> put_p(p) |> reconcile()}
  end

  defp track_infos(state, p, names) do
    for name <- Enum.sort(names) do
      sub = p.subs[name]

      track = Track.new(name)

      %{
        mid: sub.mid,
        track: name,
        kind: track.kind,
        source: with({_, source} <- Track.parse(name), do: source),
        participant_id:
          owner(state, name) || (Map.has_key?(state.ghosts, name) && owner_id(name)) || nil,
        worker_id: get_in(state.outlets, [name, :worker_id]),
        gain: sub.gain
      }
    end
  end

  defp public(p) do
    tracks =
      for {source, %{status: :live, muted: muted}} <- p.tracks, into: %{} do
        {source, %{kind: Track.kind(source), muted: muted}}
      end

    %Participant{id: p.id, meta: p.meta, tracks: tracks}
  end

  defp mic_status(p) do
    case p.tracks["mic"] do
      %{status: status} -> status
      nil when p.media in [:publishing, :adopting] -> p.media
      nil -> :none
    end
  end

  # Sources `p` may publish: known ones, limited by its metadata's
  # `:publish` list when there is one.
  defp check_sources(_p, []), do: {:error, :no_sources}

  defp check_sources(p, sources) do
    allowed = publish_list(p.meta)

    cond do
      Enum.any?(sources, &(Track.kind(&1) == nil)) -> {:error, :unknown_source}
      allowed == :invalid -> {:error, :not_allowed}
      allowed != nil and Enum.any?(sources, &(&1 not in allowed)) -> {:error, :not_allowed}
      true -> :ok
    end
  end

  # Participant metadata: a map, whose `:publish` (or `"publish"`), when
  # present, lists the sources it may publish. Joins and `update_meta/3`
  # refuse anything else.
  defp meta?(meta), do: publish_list(meta) != :invalid

  # The metadata's publish list, nil when it has none, or `:invalid`.
  # Metadata that slipped past `meta?/1` (a resume with data that didn't
  # come from a join) is refused publishing rather than crashing the room.
  defp publish_list(meta) when is_map(meta) do
    case Map.get(meta, :publish) || Map.get(meta, "publish") do
      nil -> nil
      list -> if strings?(list), do: list, else: :invalid
    end
  end

  defp publish_list(_meta), do: :invalid

  defp strings?([]), do: true
  defp strings?([s | rest]) when is_binary(s), do: strings?(rest)
  defp strings?(_), do: false

  defp room(state) do
    %Room{
      id: state.id,
      participants: Enum.map(participants(state), &public/1),
      workers: state.worker_specs,
      assigns: state.assigns
    }
  end

  # Track name => :pending | :live.
  defp directory(state) do
    mics =
      for {id, p} <- state.participants,
          {source, %{status: status}} <- p.tracks,
          status in [:pending, :live],
          into: %{},
          do: {track_name(id, source), status}

    outputs =
      for {name, %{status: status}} <- state.outlets, status in [:pending, :live], into: %{} do
        {name, status}
      end

    ghosts = Map.new(state.ghosts, fn {name, _} -> {name, :live} end)
    ghosts |> Map.merge(outputs) |> Map.merge(mics)
  end

  # Track name => where it lives at Cloudflare.
  defp sessions(state) do
    mics =
      for {id, %{session_id: s} = p} <- state.participants,
          {source, %{status: status}} <- p.tracks,
          status in [:pending, :live],
          into: %{} do
        name = track_name(id, source)
        {name, %{session_id: s, track_name: name}}
      end

    outputs =
      for {name, %{status: status} = o} <- state.outlets,
          status in [:pending, :live],
          into: %{} do
        {name, %{session_id: o.session_id, track_name: o.cf_track}}
      end

    state.ghosts |> Map.merge(outputs) |> Map.merge(mics)
  end

  # A published track's room-scoped name is also its track name at
  # Cloudflare, so a pull read back from Cloudflare says whose track it is.
  defp track_name(id, source), do: "#{id}/#{source}"

  # The participant whose track `name` is, or nil for a worker's output.
  defp owner(state, name) do
    case owner_id(name) do
      nil -> nil
      id -> if Map.has_key?(state.participants, id), do: id
    end
  end

  defp owner_id(name) do
    case Track.parse(name) do
      {id, _source} -> id
      nil -> nil
    end
  end

  # A pulled track's room name from its Cloudflare track name, and whether
  # it's stale. Participants' tracks are named the same at Cloudflare. A worker output's
  # session (its peer's) dies with the run that created it, so its pulls
  # are always stale after a restart.
  defp adopted_name("out-" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, name} -> {name, true}
      :error -> {"out-" <> encoded, true}
    end
  end

  defp adopted_name(name) do
    if owner_id(name), do: {name, false}, else: {name, true}
  end

  # Ghost tracks `p` still holds that its policy doesn't (yet) mention.
  defp held_ghosts(%{ghosts: ghosts}, _p, _wanted) when map_size(ghosts) == 0, do: []

  defp held_ghosts(state, p, wanted) do
    named =
      MapSet.new(wanted, fn
        %Track{name: n} -> n
        n when is_binary(n) -> n
      end)

    for {name, %{status: :open, gain: gain}} <- p.subs,
        Map.has_key?(state.ghosts, name),
        not MapSet.member?(named, name),
        do: %{Track.new(name) | gain: gain}
  end

  defp put_p(state, p), do: put_in(state.participants[p.id], p)

  defp with_participant(state, id, fun) do
    case state.participants[id] do
      nil -> {:noreply, state}
      p -> {:noreply, fun.(p)}
    end
  end

  defp with_op(state, id, op_id, stage, tag, fun) do
    case state.participants[id] do
      %{op: %{id: ^op_id, stage: ^stage} = op} = p ->
        {:noreply, fun.(p, op)}

      nil ->
        {:noreply, state}

      p ->
        reply(p, tag, {:error, :stale_operation})
        {:noreply, state}
    end
  end

  ## Messages

  defp run(state, id, kind, fun) do
    server = self()

    Task.Supervisor.start_child(Octoroom.TaskSupervisor, fn ->
      result =
        try do
          fun.()
        rescue
          error -> {:error, {:exception, Exception.message(error)}}
        end

      send(server, {:result, id, kind, result})
    end)

    state
  end

  defp timeout(state, id, op_id),
    do: Process.send_after(self(), {:signal_timeout, id, op_id}, state.signal_timeout)

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  # A disconnected participant has no process; it's resynced on resume.
  defp signal(%{pid: nil}, _kind, _payload), do: :ok
  defp signal(p, kind, payload), do: send(p.pid, {:octoroom_signal, kind, payload})

  defp reply(_p, nil, _result), do: :ok
  defp reply(%{pid: nil}, _tag, _result), do: :ok
  defp reply(p, tag, result), do: send(p.pid, {:octoroom_signal, :reply, tag, result})

  defp subscriptions_event(state, p) do
    hears = for({name, %{status: :open}} <- p.subs, do: name) |> Enum.sort()
    Octoroom.broadcast(state.id, {:subscriptions, p.id, hears})
  end

  # To `scope: :room` subscribers, and to every participant's process and
  # `scope: {:participant, id}` subscribers. Those subscribers get it while
  # the participant is disconnected too: they're separate processes.
  defp event(state, event, opts \\ []) do
    Octoroom.broadcast(state.id, event)
    except = Keyword.get(opts, :except)
    recipients = for {id, _p} <- state.participants, id != except, do: id

    for id <- recipients, do: signal(state.participants[id], :room_event, event)
    Octoroom.deliver(state.id, recipients, event)
    :ok
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
