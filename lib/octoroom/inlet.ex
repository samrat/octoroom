defmodule Octoroom.Inlet do
  @moduledoc false

  # One worker input. Owns the socket of an egress adapter that streams an
  # input track's PCM, and forwards each frame to the worker by name. Because
  # it doesn't hold the worker's pid, a restarted worker picks up the same
  # stream and the adapter stays as it is. Frames that arrive while the
  # worker is down are dropped.
  #
  # Cloudflare's egress delivers slightly more audio than real time (about
  # 0.56% in one measured run), so a worker that plays its input back would
  # build latency without bound, and recordings would run long. A token
  # bucket holds each input to real time: it refills with 20 ms of audio
  # every 20 ms, holds up to @burst_ms (enough for the bursty delivery of
  # the TCP leg), and frames that find it empty are dropped.

  use GenServer, restart: :temporary

  alias Octoroom.{Adapter, Worker}

  # Bytes of adapter PCM (48 kHz stereo s16le) per millisecond.
  @bytes_per_ms 192
  @burst_ms 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "`%{forwarded, dropped}`: frames passed to the worker, and frames over real time."
  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init(%{room_id: room_id, worker_id: worker_id, input: input, ws_id: ws_id} = opts) do
    {:ok, _} = Adapter.register(:egress, ws_id)
    burst_ms = Map.get(opts, :burst_ms, @burst_ms)

    {:ok,
     %{
       room_id: room_id,
       worker_id: worker_id,
       input: input,
       burst_ms: burst_ms,
       tokens_ms: burst_ms,
       at: now(),
       forwarded: 0,
       dropped: 0
     }}
  end

  @impl true
  def handle_info({:octoroom_pcm, _socket, pcm}, state) do
    now = now()
    tokens = min(state.burst_ms, state.tokens_ms + (now - state.at) / 1000)
    cost = byte_size(pcm) / @bytes_per_ms
    state = %{state | at: now}

    if tokens >= cost do
      case Worker.whereis(state.room_id, state.worker_id) do
        nil -> :ok
        pid -> send(pid, {:octoroom_input, state.input, pcm})
      end

      {:noreply, %{state | tokens_ms: tokens - cost, forwarded: state.forwarded + 1}}
    else
      {:noreply, %{state | tokens_ms: tokens, dropped: state.dropped + 1}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state),
    do: {:reply, Map.take(state, [:forwarded, :dropped]), state}

  defp now, do: System.monotonic_time(:microsecond)
end
