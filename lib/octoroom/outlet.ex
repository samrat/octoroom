defmodule Octoroom.Outlet do
  @moduledoc """
  One worker output track. Owns the socket of the track's ingest adapter
  and paces audio to real time: Cloudflare plays whatever it is sent, so
  anything sent early would still play after a barge-in.

  Workers queue adapter PCM (48 kHz stereo s16le) with `play/3`. Every
  20 ms the outlet sends the next whole frame and sends nothing when the
  queue is empty. `flush/2` empties the queue, so at most one frame plus the
  network is already on its way. Audio played before Cloudflare has dialed
  in is dropped as it comes due, as a live stream would be.

  The first frame sent tells the room server the track is live, so
  listeners can pull it. The outlet is separate from its worker: if the
  worker crashes, the track stays published.
  """

  use GenServer, restart: :temporary

  alias Octoroom.Adapter

  @frame_ms 20
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

  @doc "Queues adapter PCM on an output track. A no-op if the outlet isn't running."
  def play(room_id, name, pcm) when is_binary(pcm), do: cast(room_id, name, {:play, pcm})

  @doc "Drops an output track's queued, unplayed audio."
  def flush(room_id, name), do: cast(room_id, name, :flush)

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
  def init(%{name: name, server: server, ws_id: ws_id}) do
    {:ok, _} = Adapter.register(:ingest, ws_id)

    {:ok,
     %{
       name: name,
       server: server,
       socket: nil,
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

  def handle_cast(:flush, state),
    do: {:noreply, %{state | buffer: <<>>, queue: :queue.new(), queued: 0}}

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      queued_ms: state.queued * @frame_ms,
      sent: state.sent,
      dropped: state.dropped,
      underruns: state.underruns,
      connected: state.socket != nil,
      live: state.live
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:timeout, _ref, :tick}, state), do: {:noreply, tick(state)}

  def handle_info({:octoroom_adapter_socket, :ingest, socket}, state) do
    Process.monitor(socket)
    {:noreply, %{state | socket: socket}}
  end

  # Cloudflare may dial again; the id stays registered while the outlet lives.
  def handle_info({:DOWN, _ref, :process, socket, _reason}, %{socket: socket} = state),
    do: {:noreply, %{state | socket: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  # Sends the frame that's due and schedules the next one. With nothing
  # queued, the clock stops; the next `play` restarts it.
  defp tick(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        underruns = if state.next, do: state.underruns + 1, else: state.underruns
        %{state | next: nil, underruns: underruns}

      {{:value, frame}, queue} ->
        state = %{state | queue: queue, queued: state.queued - 1} |> send_frame(frame)
        now = System.monotonic_time(:millisecond)
        next = if state.next, do: state.next + @frame_ms, else: now + @frame_ms
        next = if next < now - @max_lag_ms, do: now + @frame_ms, else: next
        :erlang.start_timer(next, self(), :tick, abs: true)
        %{state | next: next}
    end
  end

  defp send_frame(%{socket: nil} = state, _frame), do: %{state | dropped: state.dropped + 1}

  defp send_frame(state, frame) do
    send(state.socket, {:octoroom_pcm, frame})
    unless state.live, do: send(state.server, {:outlet_live, state.name, self()})
    %{state | live: true, sent: state.sent + 1}
  end

  defp split(<<frame::binary-size(@frame_bytes), rest::binary>>, acc),
    do: split(rest, [frame | acc])

  defp split(rest, acc), do: {Enum.reverse(acc), rest}
end
