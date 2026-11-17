defmodule Octoroom.Peer do
  @moduledoc false

  # One worker's connection to Cloudflare: its own Cloudflare session and a
  # peer connection, through which the worker's inputs are pulled and its
  # outputs pushed. The room server decides what to push, pull and close;
  # the peer carries it out in order, because a session takes one
  # offer/answer exchange at a time:
  #
  # Push:  add sendonly transceivers -> our offer -> Cloudflare `tracks/new`
  #        -> Cloudflare's answer. Each output's outlet gets a sink once the
  #        connection is up.
  # Pull:  Cloudflare `tracks/new` -> Cloudflare's offer -> our answer ->
  #        Cloudflare `renegotiate`. RTP for each pulled track goes to its
  #        inlet.
  # Close: stop the transceivers -> our offer -> Cloudflare `tracks/close`
  #        -> Cloudflare's answer.
  #
  # Requests of the same kind that queue up while another operation is in
  # flight go to Cloudflare as one call. Cloudflare calls run in tasks, so
  # the peer keeps routing RTP while one is pending (a pull of a track with
  # no packets yet is held ~8 s).
  #
  # The peer reports to the room server as
  # `{:peer_result, worker_id, peer_pid, result}`, where result is
  # `{:pushed, name, session_id}`, `{:pulled, input}`,
  # `{:pull_failed, input, reason}` or `:connected`. A push, renegotiation or close that
  # fails leaves the peer connection's signaling state unknown, so the peer
  # stops instead, and the room server starts the worker's media afresh.
  #
  # If the connection isn't up within @connect_timeout of the first
  # negotiation, or ICE fails, the peer logs why that usually happens (the
  # host blocks outbound UDP) and stops; the room server retries with
  # backoff and eventually gives up.
  #
  # The peer connection itself sits behind `Octoroom.Peer.Media`
  # (`Octoroom.Peer.WebRTC` by default), so tests can run without UDP.

  use GenServer, restart: :temporary

  require Logger

  alias Octoroom.Cloudflare

  @connect_timeout 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Pushes output track `name` (Cloudflare track name `cf_track`), played by `outlet`."
  def push(peer, name, cf_track, outlet),
    do: GenServer.cast(peer, {:request, {:push, name, cf_track, outlet}})

  @doc "Pulls `source` (`%{session_id, track_name}`) as input `input`, heard by `inlet`."
  def pull(peer, input, source, inlet),
    do: GenServer.cast(peer, {:request, {:pull, input, source, inlet}})

  @doc "Stops an output (`{:output, name}`) or an input (`{:input, input}`)."
  def close(peer, ref), do: GenServer.cast(peer, {:close, ref})

  @doc "The peer's Cloudflare session id, or nil before its first operation."
  def session(peer), do: GenServer.call(peer, :session)

  ## Server

  @impl true
  def init(opts) do
    # So `terminate/2` closes the peer connection properly when the room
    # stops the peer: Cloudflare then ends the session within seconds,
    # rather than when the connection times out.
    Process.flag(:trap_exit, true)
    media_mod = Map.get(opts, :media, Octoroom.Peer.WebRTC)
    {:ok, media} = media_mod.init(%{cloudflare: opts.cloudflare})

    {:ok,
     %{
       room_id: Map.get(opts, :room_id),
       started: System.monotonic_time(:millisecond),
       worker_id: opts.worker_id,
       server: opts.server,
       connect_timeout: Map.get(opts, :connect_timeout, @connect_timeout),
       connect_timer: nil,
       cf: opts.cloudflare,
       media_mod: media_mod,
       media: media,
       session_id: nil,
       connected: false,
       queue: [],
       op: nil,
       # name => %{mid, sink, outlet, sent: boolean}
       outputs: %{},
       # input => %{mid, ref, inlet}
       inputs: %{},
       # media ref => input
       refs: %{},
       # Refs closed while their push or pull was in flight.
       cancelled: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:session, _from, state), do: {:reply, state.session_id, state}

  @impl true
  def handle_cast({:request, request}, state),
    do: {:noreply, run_next(%{state | queue: state.queue ++ [request]})}

  def handle_cast({:close, ref}, state) do
    queued? = Enum.any?(state.queue, &(request_ref(&1) == ref))

    in_flight? =
      state.op != nil and state.op.kind in [:push, :pull] and
        Enum.any?(state.op.batch, &(request_ref(&1) == ref))

    state =
      cond do
        queued? -> %{state | queue: Enum.reject(state.queue, &(request_ref(&1) == ref))}
        in_flight? -> %{state | cancelled: MapSet.put(state.cancelled, ref)}
        true -> close_active(state, ref)
      end

    {:noreply, run_next(state)}
  end

  @impl true
  def handle_info({:step, op_id, step, result}, %{op: %{id: op_id}} = state),
    do: step(state, step, result)

  def handle_info({:step, _op_id, _step, _result}, state), do: {:noreply, state}

  # The peer connection (linked) died.
  def handle_info({:EXIT, _pid, reason}, state) when reason != :normal,
    do: stop(state, {:peer_connection_down, reason})

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info(:connect_timeout, %{connected: false} = state) do
    Logger.error(
      "Octoroom worker #{state.worker_id} couldn't connect to Cloudflare within " <>
        "#{state.connect_timeout} ms. Workers need outbound UDP to Cloudflare; " <>
        "check that this host's firewall or network allows it."
    )

    {:stop, {:shutdown, :connect_timeout}, state}
  end

  def handle_info(:connect_timeout, state), do: {:noreply, state}

  def handle_info(message, state) do
    case state.media_mod.handle_info(message, state.media) do
      {:input, ref, media} ->
        case state.refs[ref] do
          nil -> :ok
          input -> deliver(state.inputs[input].inlet, media)
        end

        {:noreply, state}

      {:connected, media} ->
        :telemetry.execute(
          [:octoroom, :peer, :connect],
          %{duration_ms: System.monotonic_time(:millisecond) - state.started},
          %{room_id: state.room_id, worker_id: state.worker_id}
        )

        report(state, :connected)
        {:noreply, send_sinks(%{state | media: media, connected: true})}

      {:failed, _media} ->
        Logger.error(
          "Octoroom worker #{state.worker_id}'s connection to Cloudflare failed " <>
            "(workers need outbound UDP to Cloudflare)"
        )

        {:stop, {:shutdown, :connection_failed}, state}

      {:ignore, media} ->
        {:noreply, %{state | media: media}}
    end
  end

  @impl true
  def terminate(_reason, state), do: state.media_mod.close(state.media)

  ## Operations

  defp run_next(%{op: nil, queue: [head | _]} = state) do
    kind = elem(head, 0)
    {batch, rest} = Enum.split_with(state.queue, &(elem(&1, 0) == kind))
    state = %{state | queue: rest}

    case batch_ready(state, kind, batch) do
      [] -> run_next(state)
      batch -> start(%{state | op: %{id: make_ref(), kind: kind, batch: batch}})
    end
  end

  defp run_next(state), do: state

  # Closes of refs that have no mid (never pushed or pulled) need nothing.
  defp batch_ready(_state, :close, batch), do: Enum.filter(batch, &elem(&1, 2))
  defp batch_ready(_state, _kind, batch), do: batch

  defp start(%{session_id: nil} = state) do
    cf = state.cf
    task(state, :session, fn -> Cloudflare.new_session(cf) end)
  end

  defp start(%{op: %{kind: :push, batch: batch}} = state) do
    {:ok, offer, slots, media} = state.media_mod.offer_sendonly(state.media, length(batch))
    items = Enum.zip(batch, slots)

    tracks =
      for {{:push, _name, cf_track, _}, slot} <- items, do: %{mid: slot.mid, track_name: cf_track}

    {cf, session} = {state.cf, state.session_id}
    state = %{state | media: media, op: Map.put(state.op, :items, items)}
    task(state, :pushed, fn -> Cloudflare.push_tracks(cf, session, offer, tracks) end)
  end

  defp start(%{op: %{kind: :pull, batch: batch}} = state) do
    sources = for {:pull, _input, source, _inlet} <- batch, do: source
    {cf, session} = {state.cf, state.session_id}
    task(state, :pulled, fn -> Cloudflare.pull_tracks(cf, session, sources) end)
  end

  defp start(%{op: %{kind: :close, batch: batch}} = state) do
    mids = for {:close, _ref, mid} <- batch, do: mid
    {:ok, offer, media} = state.media_mod.stop_and_offer(state.media, mids)
    {cf, session} = {state.cf, state.session_id}
    state = %{state | media: media}
    task(state, :closed, fn -> Cloudflare.close_tracks(cf, session, mids, offer) end)
  end

  defp step(state, :session, {:ok, session_id}) do
    media = state.media_mod.session_created(state.media, session_id)
    {:noreply, start(%{state | session_id: session_id, media: media})}
  end

  defp step(state, :pushed, {:ok, %{sdp: answer}}) do
    case state.media_mod.apply_answer(state.media, answer) do
      {:ok, media} ->
        state =
          Enum.reduce(state.op.items, %{state | media: media}, fn
            {{:push, name, _cf_track, outlet}, slot}, state ->
              output = %{mid: slot.mid, sink: slot.sink, outlet: outlet, sent: false}
              report(state, {:pushed, name, state.session_id})
              put_in(state.outputs[name], output)
          end)

        refs = for {{:push, name, _, _}, _} <- state.op.items, do: {:output, name}
        {:noreply, state |> await_connection() |> send_sinks() |> finish(refs)}

      {:error, reason} ->
        stop(state, {:push_failed, reason})
    end
  end

  defp step(state, :pulled, {:ok, %{tracks: pulled} = resp}) do
    by_source =
      Map.new(state.op.batch, fn {:pull, input, src, inlet} ->
        {{src.session_id, src.track_name}, {input, inlet}}
      end)

    {added, failed} =
      Enum.reduce(pulled, {[], []}, fn t, {added, failed} ->
        case by_source[{t.session_id, t.track_name}] do
          nil -> {added, failed}
          {input, _} when is_map_key(t, :error) -> {added, [{input, t.error} | failed]}
          {input, inlet} -> {[{input, inlet, t.mid} | added], failed}
        end
      end)

    mentioned = MapSet.new(Enum.map(added, &elem(&1, 0)) ++ Enum.map(failed, &elem(&1, 0)))

    missing =
      for {:pull, input, _, _} <- state.op.batch,
          not MapSet.member?(mentioned, input),
          do: {input, :missing}

    for {input, reason} <- failed ++ missing, do: report(state, {:pull_failed, input, reason})

    cond do
      added == [] ->
        {:noreply, finish(state, [])}

      resp.renegotiate and is_binary(resp.sdp) ->
        case state.media_mod.answer_offer(state.media, resp.sdp) do
          {:ok, answer, refs, media} ->
            {cf, session} = {state.cf, state.session_id}
            op = Map.merge(state.op, %{added: Enum.reverse(added), refs: refs})
            state = %{state | media: media, op: op}

            {:noreply,
             task(state, :renegotiated, fn -> Cloudflare.renegotiate(cf, session, answer) end)}

          {:error, reason} ->
            stop(state, {:answer_failed, reason})
        end

      true ->
        for {input, _, _} <- added, do: report(state, {:pull_failed, input, :no_offer})
        {:noreply, finish(state, [])}
    end
  end

  defp step(state, :pulled, {:error, reason}) do
    for {:pull, input, _, _} <- state.op.batch, do: report(state, {:pull_failed, input, reason})
    {:noreply, finish(state, [])}
  end

  defp step(state, :renegotiated, :ok) do
    media = state.media_mod.renegotiated(state.media)
    state = await_connection(state)

    state =
      Enum.reduce(state.op.added, %{state | media: media}, fn {input, inlet, mid}, state ->
        ref = Map.get(state.op.refs, mid, mid)
        report(state, {:pulled, input})

        %{
          state
          | inputs: Map.put(state.inputs, input, %{mid: mid, ref: ref, inlet: inlet}),
            refs: Map.put(state.refs, ref, input)
        }
      end)

    {:noreply, finish(state, Enum.map(state.op.added, &{:input, elem(&1, 0)}))}
  end

  defp step(state, :closed, {:ok, %{sdp: answer}}) when is_binary(answer) do
    case state.media_mod.apply_answer(state.media, answer) do
      {:ok, media} -> {:noreply, finish(%{state | media: media}, [])}
      {:error, reason} -> stop(state, {:close_failed, reason})
    end
  end

  defp step(state, step, {:error, reason}), do: stop(state, {:"#{step}_failed", reason})

  defp step(state, step, other), do: stop(state, {:"#{step}_failed", {:unexpected, other}})

  # Ends the operation. Refs closed while it was in flight are closed now.
  defp finish(state, refs) do
    {late, cancelled} = Enum.split_with(state.cancelled, &(&1 in refs))
    state = %{state | op: nil, cancelled: MapSet.new(cancelled)}
    state = Enum.reduce(late, state, &close_active(&2, &1))
    run_next(state)
  end

  defp close_active(state, {:output, name} = ref) do
    case Map.pop(state.outputs, name) do
      {nil, _} ->
        state

      {output, outputs} ->
        %{state | outputs: outputs, queue: state.queue ++ [{:close, ref, output.mid}]}
    end
  end

  defp close_active(state, {:input, input} = ref) do
    case Map.pop(state.inputs, input) do
      {nil, _} ->
        state

      {i, inputs} ->
        %{
          state
          | inputs: inputs,
            refs: Map.delete(state.refs, i.ref),
            queue: state.queue ++ [{:close, ref, i.mid}]
        }
    end
  end

  # After the first negotiation, the connection has a while to come up.
  defp await_connection(%{connected: false, connect_timer: nil} = state),
    do: %{
      state
      | connect_timer: Process.send_after(self(), :connect_timeout, state.connect_timeout)
    }

  defp await_connection(state), do: state

  # Outlets get their sink once the connection is up, so their first packet
  # reaches Cloudflare and the track can be pulled.
  defp send_sinks(%{connected: false} = state), do: state

  defp send_sinks(state) do
    outputs =
      Map.new(state.outputs, fn
        {name, %{sent: false} = o} ->
          send(o.outlet, {:octoroom_sink, o.sink})
          {name, %{o | sent: true}}

        other ->
          other
      end)

    %{state | outputs: outputs}
  end

  defp deliver(inlet, {:rtp, packet}), do: send(inlet, {:octoroom_rtp, packet})
  defp deliver(inlet, {:pcm, frame}), do: send(inlet, {:octoroom_pcm, self(), frame})

  defp request_ref({:push, name, _, _}), do: {:output, name}
  defp request_ref({:pull, input, _, _}), do: {:input, input}
  defp request_ref({:close, ref, _}), do: ref

  defp stop(state, reason) do
    Logger.warning("Octoroom peer for worker #{state.worker_id} stopping: #{inspect(reason)}")
    {:stop, {:shutdown, reason}, state}
  end

  defp report(state, result),
    do: send(state.server, {:peer_result, state.worker_id, self(), result})

  defp task(state, step, fun) do
    peer = self()
    op_id = state.op.id

    Task.Supervisor.start_child(Octoroom.TaskSupervisor, fn ->
      result =
        try do
          fun.()
        rescue
          error -> {:error, {:exception, Exception.message(error)}}
        end

      send(peer, {:step, op_id, step, result})
    end)

    state
  end
end

defmodule Octoroom.Peer.Media do
  @moduledoc false

  # The peer connection under an `Octoroom.Peer`. Functions run in the
  # peer's process and may block briefly (gathering host candidates).

  @type state :: term
  @typedoc "Where an outlet sends its frames: RTP through a peer connection, or a function of PCM."
  @type sink :: {:rtp, pid, term} | {:pcm, (binary -> term)}

  @callback init(%{cloudflare: map}) :: {:ok, state}
  @callback session_created(state, session_id :: String.t()) :: state
  @doc "Adds `n` sendonly audio transceivers. Returns the complete offer and one slot per transceiver."
  @callback offer_sendonly(state, n :: pos_integer) ::
              {:ok, sdp :: String.t(), [%{mid: String.t(), sink: sink}], state}
  @callback apply_answer(state, sdp :: String.t()) :: {:ok, state} | {:error, term}
  @doc "Answers Cloudflare's offer. Returns the answer and, per mid, the ref its RTP arrives under."
  @callback answer_offer(state, sdp :: String.t()) ::
              {:ok, sdp :: String.t(), %{String.t() => term}, state} | {:error, term}
  @doc "Cloudflare has the answer to the last offer."
  @callback renegotiated(state) :: state
  @callback stop_and_offer(state, mids :: [String.t()]) :: {:ok, sdp :: String.t(), state}
  @callback handle_info(term, state) ::
              {:input, ref :: term, {:rtp, term} | {:pcm, binary}}
              | {:connected, state}
              | {:failed, state}
              | {:ignore, state}
  @callback close(state) :: term
end
