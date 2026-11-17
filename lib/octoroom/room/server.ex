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
  # Each output track has an outlet (an ingest adapter's socket owner) and
  # each (worker, live input) an inlet (an egress adapter's socket owner),
  # both under the room's media supervisor. Adapters are created in batches
  # once the owning process is registered, and closed when it stops. An
  # output track is `:pending` once its adapter exists and `:live` once its
  # outlet has sent a frame.
  #
  # Messages to a participant's process (its channel) are
  # `{:octoroom_signal, kind, payload}`; replies to its requests are
  # `{:octoroom_signal, :reply, tag, result}`.

  use GenServer, restart: :temporary

  require Logger

  alias Octoroom.{Adapter, Cloudflare, Inlet, Outlet, Participant, Reconciler, Room}
  alias Octoroom.Worker

  @mic "mic"
  @max_failures 5
  @signal_timeout 15_000
  # A worker that ran this long before crashing starts its backoff afresh.
  @worker_stable_ms 30_000

  ## API (called by a participant's process)

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  def via(room_id), do: {:via, Registry, {Octoroom.Registry, {:room, room_id}}}

  def whereis(room_id) do
    case Registry.lookup(Octoroom.Registry, {:room, room_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Publishes the participant's mic from its offer. Replies `%{sdp: answer}`."
  def publish(server, participant_id, sdp, mids, tag),
    do: GenServer.cast(server, {:publish, participant_id, sdp, mids, tag})

  @doc "The participant's connection to Cloudflare is up, so its mic is flowing."
  def connected(server, participant_id),
    do: GenServer.cast(server, {:connected, participant_id})

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
    {:ok, assigns} = module.mount(room_id)
    # So `terminate/2` closes the room's adapters when the room shuts down.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       id: room_id,
       module: module,
       assigns: assigns,
       cloudflare: Keyword.get_lazy(opts, :cloudflare, &Cloudflare.config/0),
       signal_timeout: Keyword.get(opts, :signal_timeout, @signal_timeout),
       public_ws_url:
         Keyword.get_lazy(opts, :public_ws_url, fn ->
           Application.get_env(:octoroom, :public_ws_url)
         end),
       participants: %{},
       worker_specs: [],
       workers: %{},
       outlets: %{},
       inlets: %{},
       warned_url: false,
       order: [],
       failures: %{},
       retry: nil
     }}
  end

  @impl true
  def handle_call({:join, pid, meta}, _from, state) do
    id = new_id()

    p = %{
      id: id,
      meta: meta,
      pid: pid,
      monitor: Process.monitor(pid),
      session_id: nil,
      mic: :none,
      publish_tag: nil,
      subs: %{},
      op: nil
    }

    state = %{
      state
      | participants: Map.put(state.participants, id, p),
        order: state.order ++ [id]
    }

    event(state, {:joined, public(p)}, except: id)

    reply = %{
      participant_id: id,
      participants: Enum.map(participants(state), &public/1),
      ice_servers: Octoroom.ice_servers()
    }

    # The participant can't hear or be heard yet, but workers may follow it.
    {:reply, {:ok, reply}, reconcile(state)}
  end

  def handle_call({:update_meta, id, fun}, _from, state) do
    case state.participants[id] do
      nil ->
        {:reply, {:error, :no_participant}, state}

      p ->
        p = %{p | meta: fun.(p.meta)}
        state = put_in(state.participants[id], p)
        event(state, {:updated, public(p)})
        {:reply, :ok, reconcile(state)}
    end
  end

  def handle_call({:assign, key, value}, _from, state),
    do: {:reply, :ok, reconcile(%{state | assigns: Map.put(state.assigns, key, value)})}

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
            mic: p.mic,
            hears: for({name, %{status: :open}} <- p.subs, do: name) |> Enum.sort(),
            subscriptions:
              Map.new(p.subs, fn {name, s} -> {name, Map.take(s, [:status, :gain])} end)
          }
        end,
      workers:
        for spec <- state.worker_specs do
          running = state.workers[spec.id]

          spec
          |> Map.take([:id, :module, :inputs, :outputs])
          |> Map.merge(%{
            running: running != nil,
            connected:
              for({{id, input}, %{adapter_id: a}} <- state.inlets, id == spec.id, a, do: input)
              |> Enum.sort()
          })
        end,
      outputs:
        Map.new(state.outlets, fn {name, o} ->
          {name, %{status: o.status, worker: o.worker_id}}
        end)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_cast({:publish, id, sdp, mids, tag}, state) do
    with_participant(state, id, fn
      %{mic: :none} = p ->
        mid = mids["mic"] || mids[:mic]
        cf = state.cloudflare

        run(state, id, :publish, fn ->
          with {:ok, session} <- Cloudflare.new_session(cf),
               {:ok, %{sdp: answer}} <-
                 Cloudflare.push_tracks(cf, session, sdp, [%{mid: mid, track_name: @mic}]) do
            {:ok, session, answer}
          end
        end)

        put_p(state, %{p | mic: :publishing, publish_tag: tag})

      p ->
        reply(p, tag, {:error, :already_published})
        state
    end)
  end

  def handle_cast({:connected, id}, state) do
    with_participant(state, id, fn
      %{mic: :pending} = p ->
        p = %{p | mic: :live}
        state = put_p(state, p)
        # Earlier pulls of this track may have failed while it was empty.
        name = mic_name(id)
        failures = Map.reject(state.failures, fn {{_, n}, _} -> n == name end)
        event(state, {:published, public(p)})
        reconcile(%{state | failures: failures})

      _ ->
        state
    end)
  end

  def handle_cast({:answer, id, op_id, sdp, tag}, state) do
    with_op(state, id, op_id, :awaiting_answer, tag, fn p, op ->
      cancel(op.timer)
      cf = state.cloudflare

      run(state, id, {:renegotiated, op_id}, fn ->
        Cloudflare.renegotiate(cf, p.session_id, sdp)
      end)

      put_p(state, %{p | op: %{op | stage: :renegotiating, tag: tag, timer: nil}})
    end)
  end

  def handle_cast({:close_offer, id, op_id, sdp, tag}, state) do
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

  def handle_cast({:leave, id}, state), do: remove(state, id, :left)

  @impl true
  def handle_info({:result, id, kind, result}, state) do
    case state.participants[id] do
      nil -> {:noreply, state}
      p -> handle_result(state, p, kind, result)
    end
  end

  def handle_info({:signal_timeout, id, op_id}, state) do
    case state.participants[id] do
      %{op: %{id: ^op_id}} = p ->
        Logger.warning("Octoroom participant #{id} didn't answer signaling in time")
        signal(p, :kick, :signaling_timeout)
        remove(state, id, :kicked)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:retry, state), do: {:noreply, reconcile(%{state | retry: nil})}

  def handle_info({:outlet_live, name, pid}, state) do
    case state.outlets[name] do
      %{pid: ^pid, status: :creating} = o ->
        {:noreply, put_in(state.outlets[name], %{o | live_seen: true})}

      %{pid: ^pid, status: :pending} = o ->
        state = put_in(state.outlets[name], %{o | status: :live})
        failures = Map.reject(state.failures, fn {{_, n}, _} -> n == name end)
        Octoroom.broadcast(state.id, {:output_live, name})
        {:noreply, reconcile(%{state | failures: failures})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:adapters, requested, result}, state),
    do: {:noreply, state |> adapters_created(requested, result) |> reconcile()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case monitored(state, ref) do
      {:participant, id} ->
        remove(state, id, :left)

      {:worker, id} ->
        {:noreply, state |> worker_down(id, reason) |> reconcile()}

      {:outlet, name} ->
        Logger.warning("Octoroom outlet #{name} stopped: #{inspect(reason)}")
        {outlet, outlets} = Map.pop(state.outlets, name)
        close_adapters(state, [outlet.adapter_id])
        {:noreply, reconcile(%{state | outlets: outlets})}

      {:inlet, key} ->
        Logger.warning("Octoroom inlet #{inspect(key)} stopped: #{inspect(reason)}")
        {inlet, inlets} = Map.pop(state.inlets, key)
        close_adapters(state, [inlet.adapter_id])
        {:noreply, reconcile(%{state | inlets: inlets})}

      nil ->
        {:noreply, state}
    end
  end

  # Exits are trapped for `terminate/2`; the parent's is handled by
  # GenServer, and nothing else is linked.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    ids =
      for {_, %{adapter_id: id}} <- Map.to_list(state.outlets) ++ Map.to_list(state.inlets),
          id != nil,
          do: id

    close_adapters(state, ids)
  end

  ## Results of Cloudflare calls

  defp handle_result(state, p, :publish, {:ok, session, answer}) do
    reply(p, p.publish_tag, {:ok, %{sdp: answer}})
    {:noreply, put_p(state, %{p | session_id: session, mic: :pending, publish_tag: nil})}
  end

  defp handle_result(state, p, :publish, {:error, reason}) do
    Logger.warning("Octoroom publish failed for #{p.id}: #{inspect(reason)}")
    reply(p, p.publish_tag, {:error, reason})
    {:noreply, put_p(state, %{p | mic: :none, publish_tag: nil})}
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
            signal(p, :renegotiate, %{op_id: op_id, sdp: resp.sdp})
            {:noreply, put_p(state, %{p | op: %{p.op | stage: :awaiting_answer, timer: timer}})}

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
        signal(p, :tracks, %{added: [], removed: op.mids})
        p = %{p | subs: Map.drop(p.subs, op.names), op: nil}
        state = put_p(state, p)
        subscriptions_event(state, p)
        {:noreply, reconcile(state)}

      {:error, reason} ->
        reply(p, op.tag, {:error, reason})
        kick(state, p, {:close_failed, reason})
    end
  end

  # A result for an operation that was superseded (the participant was
  # kicked and rejoined, or a timeout fired).
  defp handle_result(state, _p, _kind, _result), do: {:noreply, state}

  defp finish_pull(state, %{op: op} = p) do
    added =
      for name <- Enum.sort(op.names) do
        sub = p.subs[name]

        %{
          mid: sub.mid,
          track: name,
          participant_id: owner(state, name),
          worker_id: get_in(state.outlets, [name, :worker_id]),
          gain: sub.gain
        }
      end

    signal(p, :tracks, %{added: added, removed: []})
    subs = Enum.reduce(op.names, p.subs, fn name, subs -> put_in(subs[name].status, :open) end)
    failures = Map.drop(state.failures, Enum.map(op.names, &{p.id, &1}))
    p = %{p | subs: subs, op: nil}
    state = put_p(%{state | failures: failures}, p)
    subscriptions_event(state, p)
    reconcile(state)
  end

  ## Reconcile

  defp reconcile(state) do
    specs = state.module.workers(room(state))
    state = reconcile_workers(%{state | worker_specs: Enum.uniq_by(specs, & &1.id)})
    room = room(state)

    desired =
      for %{mic: :live} = p <- participants(state), into: %{} do
        {p.id, state.module.subscriptions(public(p), room)}
      end

    actual = %{
      subscriptions: Map.new(state.participants, fn {id, p} -> {id, p.subs} end),
      tracks: directory(state)
    }

    ops = Reconciler.diff(desired, actual)

    state =
      ops
      |> Enum.group_by(&elem(&1, 1))
      |> Enum.reduce(state, fn {id, ops}, state ->
        apply_ops(state, state.participants[id], ops)
      end)

    schedule_retry(state)
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

    cond do
      p.op != nil -> put_p(state, p)
      closes != [] -> start_close(state, p, closes)
      opens != [] -> start_pull(state, p, opens)
      true -> put_p(state, p)
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
      timer: nil
    }

    put_p(state, %{p | subs: subs, op: op})
  end

  defp start_close(state, p, names) do
    op_id = new_id()
    mids = Enum.map(names, &p.subs[&1].mid)
    subs = Enum.reduce(names, p.subs, fn name, subs -> put_in(subs[name].status, :closing) end)
    timer = timeout(state, p.id, op_id)
    signal(p, :close, %{op_id: op_id, mids: mids})

    op = %{
      id: op_id,
      kind: :close,
      stage: :awaiting_offer,
      names: names,
      mids: mids,
      tag: nil,
      timer: timer
    }

    put_p(state, %{p | subs: subs, op: op})
  end

  defp fail(state, _id, []), do: state

  # Each failure backs off (0.5 s, 1 s, 2 s, ...) and is given up after
  # @max_failures. Keys are `{participant_id, track}` for pulls (cleared
  # when the track is published again), `{:worker, id}` for workers that
  # failed to start or crashed, and `{:media, {:outlet | :inlet, key}}` for
  # adapters Cloudflare refused.
  defp fail(state, id, failed) do
    now = System.monotonic_time(:millisecond)

    failures =
      Enum.reduce(failed, state.failures, fn {name, reason}, acc ->
        Logger.info("Octoroom #{inspect(id)} #{inspect(name)} failed: #{inspect(reason)}")
        count = Map.get(acc, {id, name}, %{count: 0}).count + 1
        Map.put(acc, {id, name}, %{count: count, at: now + 250 * Integer.pow(2, count)})
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

  ## Workers

  defp reconcile_workers(state) do
    actual = %{
      workers: Map.new(state.workers, fn {id, w} -> {id, w.spec} end),
      outlets: Map.new(state.outlets, fn {name, o} -> {name, o.worker_id} end),
      inlets: Map.keys(state.inlets),
      tracks: directory(state)
    }

    {state, requests} =
      state.worker_specs
      |> Reconciler.diff_workers(actual)
      |> Enum.reduce({state, []}, fn op, {state, requests} ->
        apply_worker_op(op, state, requests)
      end)

    create_adapters(state, Enum.reverse(requests))
  end

  defp apply_worker_op({:stop_inlet, key}, state, requests) do
    {inlet, inlets} = Map.pop(state.inlets, key)
    stop_child(state, :media, inlet)
    close_adapters(state, [inlet.adapter_id])
    {%{state | inlets: inlets}, requests}
  end

  defp apply_worker_op({:stop_outlet, name}, state, requests) do
    {outlet, outlets} = Map.pop(state.outlets, name)
    stop_child(state, :media, outlet)
    close_adapters(state, [outlet.adapter_id])
    {%{state | outlets: outlets}, requests}
  end

  defp apply_worker_op({:stop_worker, id}, state, requests),
    do: {stop_worker(state, id), requests}

  defp apply_worker_op({:start_worker, spec}, state, requests),
    do: {start_worker(state, spec), requests}

  defp apply_worker_op({:restart_worker, spec}, state, requests),
    do: {state |> stop_worker(spec.id) |> start_worker(spec), requests}

  defp apply_worker_op({:update_worker, spec}, state, requests) do
    w = state.workers[spec.id]
    send(w.pid, {:octoroom_io, spec.inputs, spec.outputs})
    {put_in(state.workers[spec.id].spec, spec), requests}
  end

  defp apply_worker_op({:start_outlet, name, worker_id}, state, requests) do
    with {:ok, url} <- public_ws_url(state),
         true <- may_retry?(state, :media, {:outlet, name}) do
      ws_id = Adapter.new_id()
      opts = %{room_id: state.id, name: name, server: self(), ws_id: ws_id}

      case start_child(state, :media, {Outlet, opts}) do
        {:ok, pid} ->
          outlet = %{
            pid: pid,
            monitor: Process.monitor(pid),
            ws_id: ws_id,
            worker_id: worker_id,
            # Track names are unique per Cloudflare session; each ingest
            # adapter gets its own session, so any safe name will do.
            cf_track: "out-" <> Base.url_encode64(name, padding: false),
            adapter_id: nil,
            session_id: nil,
            status: :creating,
            live_seen: false
          }

          request = %{
            location: "local",
            trackName: outlet.cf_track,
            endpoint: Adapter.url(url, :ingest, ws_id),
            inputCodec: "pcm"
          }

          {put_in(state.outlets[name], outlet), [{{:outlet, name, ws_id}, request} | requests]}

        {:error, reason} ->
          {fail(state, :media, [{{:outlet, name}, reason}]), requests}
      end
    else
      {:error, state} -> {state, requests}
      false -> {state, requests}
    end
  end

  defp apply_worker_op({:start_inlet, {worker_id, input} = key}, state, requests) do
    source = sessions(state)[input]

    with true <- Map.has_key?(state.workers, worker_id) and source != nil,
         {:ok, url} <- public_ws_url(state),
         true <- may_retry?(state, :media, {:inlet, key}) do
      ws_id = Adapter.new_id()
      opts = %{room_id: state.id, worker_id: worker_id, input: input, ws_id: ws_id}

      case start_child(state, :media, {Inlet, opts}) do
        {:ok, pid} ->
          inlet = %{pid: pid, monitor: Process.monitor(pid), ws_id: ws_id, adapter_id: nil}

          request = %{
            location: "remote",
            sessionId: source.session_id,
            trackName: source.track_name,
            endpoint: Adapter.url(url, :egress, ws_id),
            outputCodec: "pcm"
          }

          {put_in(state.inlets[key], inlet), [{{:inlet, key, ws_id}, request} | requests]}

        {:error, reason} ->
          {fail(state, :media, [{{:inlet, key}, reason}]), requests}
      end
    else
      {:error, state} -> {state, requests}
      false -> {state, requests}
    end
  end

  defp start_worker(state, spec) do
    if may_retry?(state, :worker, spec.id) do
      opts = %{
        room_id: state.id,
        spec: spec,
        participants: Enum.map(participants(state), &public/1)
      }

      case start_child(state, :workers, {Worker.Server, opts}) do
        {:ok, pid} ->
          w = %{
            spec: spec,
            pid: pid,
            monitor: Process.monitor(pid),
            started: System.monotonic_time(:millisecond)
          }

          put_in(state.workers[spec.id], w)

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
    ran = System.monotonic_time(:millisecond) - w.started

    failures =
      if ran > @worker_stable_ms,
        do: Map.delete(state.failures, {:worker, id}),
        else: state.failures

    fail(%{state | workers: workers, failures: failures}, :worker, [{id, reason}])
  end

  defp create_adapters(state, []), do: state

  defp create_adapters(state, requests) do
    cf = state.cloudflare
    keys = Enum.map(requests, &elem(&1, 0))
    tracks = Enum.map(requests, &elem(&1, 1))
    server = self()

    Task.Supervisor.start_child(Octoroom.TaskSupervisor, fn ->
      result =
        try do
          Cloudflare.new_adapters(cf, tracks)
        rescue
          error -> {:error, {:exception, Exception.message(error)}}
        end

      send(server, {:adapters, keys, result})
    end)

    state
  end

  # Results come back in request order. An adapter whose owner stopped in
  # the meantime is closed at once.
  defp adapters_created(state, keys, {:ok, created}) when length(keys) == length(created) do
    Enum.zip(keys, created)
    |> Enum.reduce(state, fn
      {{:outlet, name, ws_id}, adapter}, state ->
        case state.outlets[name] do
          %{ws_id: ^ws_id} = o ->
            status = if o.live_seen, do: :live, else: :pending
            if status == :live, do: Octoroom.broadcast(state.id, {:output_live, name})

            o = %{
              o
              | adapter_id: adapter.adapter_id,
                session_id: adapter.session_id,
                status: status
            }

            put_in(state.outlets[name], o)

          _ ->
            close_adapters(state, [adapter.adapter_id])
            state
        end

      {{:inlet, key, ws_id}, adapter}, state ->
        case state.inlets[key] do
          %{ws_id: ^ws_id} = i ->
            put_in(state.inlets[key], %{i | adapter_id: adapter.adapter_id})

          _ ->
            close_adapters(state, [adapter.adapter_id])
            state
        end
    end)
  end

  defp adapters_created(state, keys, result) do
    reason =
      case result do
        {:error, reason} -> reason
        other -> {:unexpected_adapters_result, other}
      end

    Logger.warning("Octoroom couldn't create adapters: #{inspect(reason)}")

    Enum.reduce(keys, state, fn
      {:outlet, name, ws_id}, state ->
        case state.outlets[name] do
          %{ws_id: ^ws_id} = o ->
            stop_child(state, :media, o)
            state = %{state | outlets: Map.delete(state.outlets, name)}
            fail(state, :media, [{{:outlet, name}, reason}])

          _ ->
            state
        end

      {:inlet, key, ws_id}, state ->
        case state.inlets[key] do
          %{ws_id: ^ws_id} = i ->
            stop_child(state, :media, i)
            state = %{state | inlets: Map.delete(state.inlets, key)}
            fail(state, :media, [{{:inlet, key}, reason}])

          _ ->
            state
        end
    end)
  end

  defp close_adapters(state, ids) do
    case Enum.reject(ids, &is_nil/1) do
      [] ->
        :ok

      ids ->
        cf = state.cloudflare

        Task.Supervisor.start_child(Octoroom.TaskSupervisor, fn ->
          case Cloudflare.close_adapters(cf, ids) do
            :ok ->
              :ok

            error ->
              Logger.warning(
                "Octoroom couldn't close adapters #{inspect(ids)}: #{inspect(error)}"
              )
          end
        end)

        :ok
    end
  end

  defp public_ws_url(%{public_ws_url: url} = state) when url in [nil, ""] do
    unless state.warned_url do
      Logger.error(
        "Octoroom room #{state.id} has workers with inputs or outputs, but `config :octoroom, " <>
          "public_ws_url:` isn't set, so Cloudflare can't reach them"
      )
    end

    {:error, %{state | warned_url: true}}
  end

  defp public_ws_url(%{public_ws_url: url}), do: {:ok, url}

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

  defp sup_name(state, :media), do: Room.Supervisor.media(state.id)
  defp sup_name(state, :workers), do: Room.Supervisor.workers(state.id)

  defp monitored(state, ref) do
    find = fn map, kind ->
      Enum.find_value(map, fn {key, v} -> if v.monitor == ref, do: {kind, key} end)
    end

    find.(state.participants, :participant) || find.(state.workers, :worker) ||
      find.(state.outlets, :outlet) || find.(state.inlets, :inlet)
  end

  ## Participants

  defp remove(state, id, reason) do
    case Map.pop(state.participants, id) do
      {nil, _} ->
        {:noreply, state}

      {p, participants} ->
        Process.demonitor(p.monitor, [:flush])
        if p.op, do: cancel(p.op.timer)
        if p.publish_tag, do: reply(p, p.publish_tag, {:error, reason})

        state = %{
          state
          | participants: participants,
            order: List.delete(state.order, id),
            failures: Map.reject(state.failures, fn {{pid, _}, _} -> pid == id end)
        }

        event(state, {:left, public(p)})

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

  defp public(p), do: %Participant{id: p.id, meta: p.meta}

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
      for {id, %{mic: mic}} <- state.participants, mic in [:pending, :live], into: %{} do
        {mic_name(id), mic}
      end

    outputs =
      for {name, %{status: status}} <- state.outlets, status in [:pending, :live], into: %{} do
        {name, status}
      end

    Map.merge(outputs, mics)
  end

  # Track name => where it lives at Cloudflare.
  defp sessions(state) do
    mics =
      for {id, %{mic: mic, session_id: s}} <- state.participants,
          mic in [:pending, :live],
          into: %{} do
        {mic_name(id), %{session_id: s, track_name: @mic}}
      end

    outputs =
      for {name, %{status: status} = o} <- state.outlets,
          status in [:pending, :live],
          into: %{} do
        {name, %{session_id: o.session_id, track_name: o.cf_track}}
      end

    Map.merge(outputs, mics)
  end

  defp mic_name(id), do: "#{id}/#{@mic}"

  # The participant whose mic `name` is, or nil for a worker's output.
  defp owner(state, name) do
    case String.split(name, "/") do
      [id, @mic] -> if Map.has_key?(state.participants, id), do: id
      _ -> nil
    end
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

  defp signal(p, kind, payload), do: send(p.pid, {:octoroom_signal, kind, payload})

  defp reply(_p, nil, _result), do: :ok
  defp reply(p, tag, result), do: send(p.pid, {:octoroom_signal, :reply, tag, result})

  defp subscriptions_event(state, p) do
    hears = for({name, %{status: :open}} <- p.subs, do: name) |> Enum.sort()
    Octoroom.broadcast(state.id, {:subscriptions, p.id, hears})
  end

  # To subscribers of the room's events, and to every participant's process.
  defp event(state, event, opts \\ []) do
    Octoroom.broadcast(state.id, event)
    except = Keyword.get(opts, :except)

    for {id, p} <- state.participants, id != except do
      signal(p, :room_event, event)
    end

    :ok
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
