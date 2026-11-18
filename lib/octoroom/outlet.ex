defmodule Octoroom.Outlet do
  @moduledoc """
  One worker output track. Paces audio to real time and sends it, Opus
  encoded, through the worker's peer connection: Cloudflare forwards
  whatever it is sent, so anything sent early would still play after a
  barge-in.

  Workers queue room PCM (48 kHz stereo s16le) with `play/3`. Every 20 ms
  the outlet sends the next whole frame and sends nothing when the queue is
  empty. `flush/2` empties the queue, so at most one frame plus the network
  is already on its way, and says how much audio it dropped: what was
  queued minus that is what listeners heard. Audio played before the track is pushed and its
  connection is up is dropped as it comes due, as a live stream would be.

  The first frame sent tells the room server the track is live, so
  listeners can pull it. The outlet is separate from its worker: if the
  worker crashes, the track stays published.
  """

  use GenServer, restart: :temporary

  alias ExWebRTC.PeerConnection

  @frame_ms 20
  # Samples per frame at Opus's 48 kHz RTP clock.
  @frame_samples 960
  # 20 ms of 48 kHz stereo s16le.
  @frame_bytes 3_840
  # Behind by more than this (a long GC pause, a suspended VM), the clock
  # restarts instead of sending a burst to catch up.
  @max_lag_ms 100

  def start_link(%{room_id: room_id, name: name} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(room_id, name))

  def via(room_id, name), do: {:via, Registry, {Octoroom.Registry, {:outlet, room_id, name}}}

  def whereis(room_id, name) do
    case Registry.lookup(Octoroom.Registry, {:outlet, room_id, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Queues room PCM on an output track. A no-op if the outlet isn't running."
  def play(room_id, name, pcm) when is_binary(pcm), do: cast(room_id, name, {:play, pcm})

  @doc """
  Drops an output track's queued, unplayed audio. Returns how many ms of
  audio it dropped, or nil if the outlet isn't running.
  """
  def flush(room_id, name) do
    case whereis(room_id, name) do
      nil -> nil
      pid -> GenServer.call(pid, :flush)
    end
  catch
    # The outlet stopped while flushing: nothing more will play.
    :exit, _reason -> nil
  end

  @doc """
  `%{queued_ms, sent, dropped, underruns, connected, live}` for an output
  track, or nil if it isn't running. `underruns` counts the times the queue
  ran dry while playing.
  """
  def stats(room_id, name) do
    case whereis(room_id, name) do
      nil -> nil
      pid -> GenServer.call(pid, :stats)
    end
  end

  defp cast(room_id, name, message) do
    case whereis(room_id, name) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  @impl true
  def init(%{name: name, server: server}) do
    {:ok,
     %{
       name: name,
       server: server,
       # Where frames go, from the worker's peer: `{:rtp, pc, track_id}` or
       # `{:pcm, fun}` (tests).
       sink: nil,
       encoder: nil,
       seq: :rand.uniform(65_536) - 1,
       timestamp: :rand.uniform(4_294_967_296) - 1,
       # Whether the next frame starts a talkspurt (the clock restarted).
       spurt: true,
       last_sent: nil,
       buffer: <<>>,
       queue: :queue.new(),
       queued: 0,
       next: nil,
       live: false,
       sent: 0,
       dropped: 0,
       underruns: 0
     }}
  end

  @impl true
  def handle_cast({:play, pcm}, state) do
    {frames, buffer} = split(state.buffer <> pcm, [])
    queue = Enum.reduce(frames, state.queue, &:queue.in/2)
    state = %{state | buffer: buffer, queue: queue, queued: state.queued + length(frames)}
    {:noreply, if(state.next == nil and state.queued > 0, do: tick(state), else: state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    dropped_ms = state.queued * @frame_ms + div(byte_size(state.buffer) * @frame_ms, @frame_bytes)
    {:reply, dropped_ms, %{state | buffer: <<>>, queue: :queue.new(), queued: 0}}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      queued_ms: state.queued * @frame_ms,
      sent: state.sent,
      dropped: state.dropped,
      underruns: state.underruns,
      connected: state.sink != nil,
      live: state.live
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:timeout, _ref, :tick}, state), do: {:noreply, tick(state)}

  def handle_info({:octoroom_sink, sink}, state), do: {:noreply, %{state | sink: sink}}

  def handle_info(_message, state), do: {:noreply, state}

  # Sends the frame that's due and schedules the next one. With nothing
  # queued, the clock stops; the next `play` restarts it.
  defp tick(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        underruns = if state.next, do: state.underruns + 1, else: state.underruns
        %{state | next: nil, underruns: underruns, spurt: true}

      {{:value, frame}, queue} ->
        state = %{state | queue: queue, queued: state.queued - 1} |> send_frame(frame)
        now = System.monotonic_time(:millisecond)
        next = if state.next, do: state.next + @frame_ms, else: now + @frame_ms
        next = if next < now - @max_lag_ms, do: now + @frame_ms, else: next
        :erlang.start_timer(next, self(), :tick, abs: true)
        %{state | next: next}
    end
  end

  defp send_frame(%{sink: nil} = state, _frame), do: %{state | dropped: state.dropped + 1}

  defp send_frame(state, frame) do
    state = deliver(state, frame)
    unless state.live, do: send(state.server, {:outlet_live, state.name, self()})
    %{state | live: true, sent: state.sent + 1}
  end

  defp deliver(%{sink: {:pcm, fun}} = state, frame) do
    fun.(frame)
    state
  end

  defp deliver(%{sink: {:rtp, pc, track_id}} = state, frame) do
    encoder = state.encoder || new_encoder()
    {:ok, payload} = Membrane.Opus.Encoder.Native.encode_packet(encoder, frame, @frame_samples)
    now = System.monotonic_time(:millisecond)

    # After a pause, the RTP clock moves on by the time that passed, and the
    # marker bit starts a talkspurt, so the receiver doesn't stretch the gap.
    timestamp =
      if state.spurt and state.last_sent,
        do: state.timestamp + max(@frame_samples, (now - state.last_sent) * 48),
        else: state.timestamp + @frame_samples

    packet =
      ExRTP.Packet.new(payload,
        sequence_number: state.seq,
        timestamp: rem(timestamp, 4_294_967_296),
        marker: state.spurt
      )

    PeerConnection.send_rtp(pc, track_id, packet)

    %{
      state
      | encoder: encoder,
        seq: rem(state.seq + 1, 65_536),
        timestamp: rem(timestamp, 4_294_967_296),
        spurt: false,
        last_sent: now
    }
  end

  # VoIP application, automatic bitrate, voice signal.
  defp new_encoder, do: Membrane.Opus.Encoder.Native.create(48_000, 2, 2048, -1000, 3001)

  defp split(<<frame::binary-size(@frame_bytes), rest::binary>>, acc),
    do: split(rest, [frame | acc])

  defp split(rest, acc), do: {Enum.reverse(acc), rest}
end
