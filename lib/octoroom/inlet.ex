defmodule Octoroom.Inlet do
  @moduledoc false

  # One worker input. Its worker's peer sends it the input track's RTP
  # (`{:octoroom_rtp, packet}`), which goes through a jitter buffer and an
  # Opus decoder to room PCM (48 kHz stereo s16le), and is forwarded to the
  # worker by name. Because it doesn't hold the worker's pid, a restarted
  # worker picks up the same stream and nothing at Cloudflare changes.
  # Frames that arrive while the worker is down are dropped. Tests send PCM
  # directly (`{:octoroom_pcm, from, pcm}`).
  #
  # A token bucket holds each input to real time: it refills with 20 ms of
  # audio every 20 ms, holds up to @burst_ms, and frames that find it empty
  # are dropped. Cloudflare's WebSocket adapters delivered ~0.56% more audio
  # than real time, which made a worker that plays its input back build
  # latency without bound; senders' clocks drift too.

  use GenServer, restart: :temporary

  alias ExWebRTC.RTP.JitterBuffer
  alias Octoroom.Worker

  # Bytes of room PCM (48 kHz stereo s16le) per millisecond.
  @bytes_per_ms 192
  @burst_ms 300
  @jitter_ms 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "`%{forwarded, dropped}`: frames passed to the worker, and frames over real time."
  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init(%{room_id: room_id, worker_id: worker_id, input: input} = opts) do
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
       dropped: 0,
       jitter: JitterBuffer.new(latency: Map.get(opts, :jitter_ms, @jitter_ms)),
       jitter_timer: nil,
       # Opus decoders by channel count: libopus's NIF only decodes packets
       # with its own count, and browsers send mono.
       decoders: %{},
       undecodable: 0
     }}
  end

  @impl true
  def handle_info({:octoroom_rtp, packet}, state) do
    {packets, timer, jitter} = JitterBuffer.insert(state.jitter, packet)
    {:noreply, %{state | jitter: jitter} |> set_timer(timer) |> decode(packets)}
  end

  def handle_info(:jitter_timeout, state) do
    {packets, timer, jitter} = JitterBuffer.handle_timeout(state.jitter)

    {:noreply,
     %{state | jitter: jitter, jitter_timer: nil} |> set_timer(timer) |> decode(packets)}
  end

  def handle_info({:octoroom_pcm, _from, pcm}, state), do: {:noreply, forward(state, pcm)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state),
    do: {:reply, Map.take(state, [:forwarded, :dropped, :undecodable]), state}

  defp decode(state, packets) do
    Enum.reduce(packets, state, fn packet, state ->
      case packet.payload do
        <<>> -> state
        payload -> decode_packet(state, payload)
      end
    end)
  end

  # The TOC byte's `s` bit says whether the packet is stereo.
  defp decode_packet(state, <<_config::5, stereo::1, _::2, _::binary>> = payload) do
    channels = stereo + 1

    decoder =
      Map.get_lazy(state.decoders, channels, fn ->
        Membrane.Opus.Decoder.Native.create(48_000, channels)
      end)

    state = put_in(state.decoders[channels], decoder)

    try do
      pcm = Membrane.Opus.Decoder.Native.decode_packet(decoder, payload)
      forward(state, if(channels == 1, do: upmix(pcm), else: pcm))
    catch
      _kind, _reason -> %{state | undecodable: state.undecodable + 1}
    end
  end

  defp upmix(pcm), do: for(<<s::binary-size(2) <- pcm>>, into: <<>>, do: s <> s)

  defp forward(state, pcm) do
    now = now()
    tokens = min(state.burst_ms, state.tokens_ms + (now - state.at) / 1000)
    cost = byte_size(pcm) / @bytes_per_ms
    state = %{state | at: now}

    if tokens >= cost do
      case Worker.whereis(state.room_id, state.worker_id) do
        nil -> :ok
        pid -> send(pid, {:octoroom_input, state.input, pcm})
      end

      %{state | tokens_ms: tokens - cost, forwarded: state.forwarded + 1}
    else
      %{state | tokens_ms: tokens, dropped: state.dropped + 1}
    end
  end

  defp set_timer(state, nil), do: state

  defp set_timer(state, ms) do
    if state.jitter_timer, do: Process.cancel_timer(state.jitter_timer)
    %{state | jitter_timer: Process.send_after(self(), :jitter_timeout, ms)}
  end

  defp now, do: System.monotonic_time(:microsecond)
end
