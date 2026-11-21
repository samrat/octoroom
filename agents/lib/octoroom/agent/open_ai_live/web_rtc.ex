defmodule Octoroom.Agent.OpenAILive.WebRTC do
  @moduledoc false

  # One OpenAI Live WebRTC connection (`POST https://api.openai.com/v1/live/sessions`)
  # paired with its sideband control WebSocket
  # (`wss://api.openai.com/v1/live/sessions/{session_id}/attach`).
  #
  # Using the sideband WebSocket for control events avoids requiring SCTP /
  # `ex_sctp` (Rust) while still running a standard WebRTC session with Opus
  # RTP media, real-time pacing, server-side barge-in, and standby mode
  # (`idle_timeout_s` + `wake_policy`).
  #
  # Sends `parent` `{:openai_live_socket, event}` for each decoded sideband
  # event (see `Protocol`) and incoming speech audio decoded to 24 kHz mono
  # PCM16, plus `:connected` and `{:disconnected, reason}`.
  #
  # A 20 ms pacer sends queued input frames and continuous Opus silence when
  # idle so OpenAI's server-side VAD and standby (`idle_timeout_s`) always see
  # an active microphone track. On the receive side, a small amplitude gate with
  # hangover filters continuous silence frames from OpenAI so presence returns
  # to `"listening"` when the model finishes speaking.

  use GenServer

  require Logger

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}
  alias ExWebRTC.RTP.JitterBuffer
  alias Octoroom.Agent.Audio.PCM16
  alias Octoroom.Agent.OpenAILive.{Protocol, Sideband}
  alias Octoroom.Audio

  @endpoint "https://api.openai.com/v1/live/sessions"
  @gather_timeout_ms 5_000
  @http_timeout_ms 15_000
  @reconnect_base_ms 250
  @reconnect_max_ms 5_000

  @frame_ms 20
  @frame_samples 960
  @frame_bytes 3_840
  @max_lag_ms 100
  @max_queued_frames 10
  @silence :binary.copy(<<0>>, @frame_bytes)

  @out_rate 24_000
  @jitter_ms 40
  # Peak absolute s16le amplitude below this (~-66 dBFS) counts as silence.
  @silence_threshold 16
  # Keep forwarding 300 ms of trailing audio after speech dips below threshold.
  @hangover_frames 15

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def send_audio(pid, audio, opts \\ []) when is_binary(audio) do
    rate = Keyword.get(opts, :sample_rate, 16_000)
    GenServer.cast(pid, {:send_audio, audio, rate})
  end

  def send_mute(pid), do: send_json(pid, Protocol.input_audio_mute_frame())
  def send_unmute(pid), do: send_json(pid, Protocol.input_audio_unmute_frame())

  def send_instructions(pid, content, opts \\ []) when is_binary(content),
    do: send_json(pid, Protocol.instructions_append_frame(content, opts))

  def send_thinking(pid, content, opts \\ []) when is_binary(content),
    do: send_json(pid, Protocol.thinking_append_frame(content, opts))

  def send_commentary(pid, content, opts \\ []) when is_binary(content),
    do: send_json(pid, Protocol.commentary_append_frame(content, opts))

  def send_tool_output(pid, call_id, output) when is_binary(call_id),
    do: send_json(pid, Protocol.tool_output_frame(call_id, output))

  def send_response_create(pid), do: send_json(pid, Protocol.response_create_frame())

  def send_json(pid, frame) when is_map(frame), do: GenServer.cast(pid, {:send_json, frame})

  def close(pid), do: GenServer.cast(pid, :close)

  @doc false
  def sideband_url(endpoint, session_id) when is_binary(endpoint) and is_binary(session_id) do
    base =
      endpoint
      |> String.trim_trailing("/")
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")

    "#{base}/#{URI.encode_www_form(session_id)}/attach"
  end

  @impl true
  def init(opts) do
    state = %{
      api_key: Keyword.fetch!(opts, :api_key),
      parent: Keyword.fetch!(opts, :parent),
      setup: Keyword.fetch!(opts, :setup),
      endpoint: Keyword.get(opts, :endpoint, @endpoint),
      # Injectable HTTP exchange `(body, api_key, endpoint) -> {:ok, %{session_id, sdp}} | ...`
      # and sideband starter `(opts) -> {:ok, pid} | {:error, reason}` for loopback tests.
      exchange: Keyword.get(opts, :exchange),
      sideband_mod: Keyword.get(opts, :sideband_mod, Sideband),
      webrtc_opts: Keyword.get(opts, :webrtc_opts),
      pc: nil,
      track_id: nil,
      session_id: nil,
      sideband: nil,
      sideband_open?: false,
      connected?: false,
      closing?: false,
      notified_disconnect?: false,
      attempt: 0,
      pending_control: [],
      # Outbound Opus RTP state
      encoder: nil,
      seq: :rand.uniform(65_536) - 1,
      timestamp: :rand.uniform(4_294_967_296) - 1,
      spurt: true,
      prev_frame: {0, 0},
      in_buffer: <<>>,
      in_queue: :queue.new(),
      in_queued: 0,
      rtp_next: nil,
      rtp_timer: nil,
      # Inbound Opus RTP state
      jitter: JitterBuffer.new(latency: @jitter_ms),
      jitter_timer: nil,
      decoders: %{},
      hangover: 0
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_audio, pcm, rate}, %{connected?: true} = state) do
    {room_pcm, prev} = Audio.to_room(pcm, rate, 1, state.prev_frame)
    {frames, rest} = split_frames(state.in_buffer <> room_pcm, [])
    {queue, queued} = enqueue_frames(state.in_queue, state.in_queued, frames)
    {:noreply, %{state | prev_frame: prev, in_buffer: rest, in_queue: queue, in_queued: queued}}
  end

  def handle_cast({:send_audio, _pcm, _rate}, state), do: {:noreply, state}

  def handle_cast({:send_json, frame}, state) do
    {:noreply, send_or_queue_control(state, frame)}
  end

  def handle_cast(:close, state) do
    state = %{state | closing?: true}

    if is_pid(state.sideband) do
      state.sideband_mod.close(state.sideband)
    end

    state = teardown(state, close_sideband: false)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:connect, %{closing?: true} = state), do: {:noreply, state}

  def handle_info(:connect, state) do
    case establish(state) do
      {:ok, state} ->
        {:noreply, %{state | attempt: 0}}

      {:error, :non_retryable, error, state} ->
        send(state.parent, {:openai_live_socket, {:error, error}})
        {:noreply, teardown(state)}

      {:error, reason, state} ->
        Logger.warning("OpenAI Live WebRTC connect failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(teardown(state), reason)}
    end
  end

  def handle_info({:timeout, _ref, :rtp_tick}, %{connected?: true, pc: pc} = state)
      when is_pid(pc) do
    {:noreply, send_rtp_tick(state)}
  end

  def handle_info({:timeout, _ref, :rtp_tick}, state), do: {:noreply, %{state | rtp_timer: nil}}

  def handle_info(:jitter_timeout, state) do
    {packets, timer, jitter} = JitterBuffer.handle_timeout(state.jitter)

    {:noreply,
     %{state | jitter: jitter, jitter_timer: nil}
     |> set_jitter_timer(timer)
     |> decode_packets(packets)}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state) do
    state = %{state | connected?: true, notified_disconnect?: false}
    send(state.parent, {:openai_live_socket, :connected})
    {:noreply, start_rtp_pacer(state)}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, status}}, %{pc: pc} = state)
      when status in [:failed, :closed] do
    if state.closing? do
      {:noreply, teardown(state)}
    else
      {:noreply, schedule_reconnect(teardown(state), {:webrtc, status})}
    end
  end

  def handle_info({:ex_webrtc, pc, {:rtp, _track_id, _rid, packet}}, %{pc: pc} = state) do
    {packets, timer, jitter} = JitterBuffer.insert(state.jitter, packet)

    {:noreply,
     %{state | jitter: jitter}
     |> set_jitter_timer(timer)
     |> decode_packets(packets)}
  end

  # -- Sideband WebSocket events --

  def handle_info({:openai_live_sideband, :connected}, state) do
    state = %{state | sideband_open?: true}

    if is_pid(state.sideband) do
      Enum.each(Enum.reverse(state.pending_control), fn frame ->
        state.sideband_mod.send_json(state.sideband, frame)
      end)
    end

    {:noreply, %{state | pending_control: []}}
  end

  def handle_info({:openai_live_sideband, {:disconnected, reason}}, state) do
    Logger.warning("OpenAI Live sideband disconnected: #{inspect(reason)}; reconnecting")
    {:noreply, %{state | sideband_open?: false}}
  end

  def handle_info({:openai_live_sideband, event}, state) do
    send(state.parent, {:openai_live_socket, event})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    teardown(state)
    :ok
  end

  # -- Signaling, PeerConnection & Sideband setup --

  defp establish(state) do
    pc_opts =
      [ice_servers: [], ice_aggressive_nomination: true, video_codecs: []]
      |> Keyword.merge(Application.get_env(:octoroom, :webrtc, []))
      |> Keyword.merge(state.webrtc_opts || [])

    {:ok, pc} = PeerConnection.start_link(pc_opts)
    track = MediaStreamTrack.new(:audio)
    {:ok, _tr} = PeerConnection.add_transceiver(pc, track, direction: :sendrecv)

    state = %{state | pc: pc, track_id: track.id}

    with {:ok, offer} <- PeerConnection.create_offer(pc),
         :ok <- PeerConnection.set_local_description(pc, offer),
         sdp = gather_local_sdp(pc),
         {:ok, %{session_id: session_id, sdp: answer_sdp}} <- exchange_sdp(state, sdp),
         :ok <-
           PeerConnection.set_remote_description(pc, %SessionDescription{
             type: :answer,
             sdp: answer_sdp
           }),
         {:ok, sideband} <- start_sideband(state, session_id) do
      {:ok, %{state | session_id: session_id, sideband: sideband}}
    else
      {:error, :non_retryable, error} -> {:error, :non_retryable, error, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_sideband(state, session_id) do
    state.sideband_mod.start_link(
      url: sideband_url(state.endpoint, session_id),
      api_key: state.api_key,
      parent: self()
    )
  end

  defp gather_local_sdp(pc) do
    if PeerConnection.get_ice_gathering_state(pc) != :complete do
      receive do
        {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
      after
        @gather_timeout_ms -> :ok
      end
    end

    PeerConnection.get_local_description(pc).sdp
  end

  defp exchange_sdp(%{exchange: fun} = state, sdp) when is_function(fun, 3) do
    body = Protocol.webrtc_session_request(state.setup, sdp)
    fun.(body, state.api_key, state.endpoint)
  end

  defp exchange_sdp(state, sdp) do
    body = Protocol.webrtc_session_request(state.setup, sdp)

    case Req.post(state.endpoint,
           headers: [{"authorization", "Bearer #{state.api_key}"}],
           json: body,
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok,
       %{
         status: status,
         body: %{"session" => %{"id" => session_id}, "transport" => %{"sdp" => answer_sdp}}
       }}
      when status in [200, 201] and is_binary(session_id) and is_binary(answer_sdp) ->
        {:ok, %{session_id: session_id, sdp: answer_sdp}}

      {:ok, %{status: status, body: resp_body}}
      when status in 400..499 and status not in [408, 429] ->
        error =
          case resp_body do
            %{"error" => err} -> err
            other -> %{"status" => status, "body" => other}
          end

        {:error, :non_retryable, error}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_or_queue_control(%{sideband_open?: true, sideband: pid} = state, frame)
       when is_pid(pid) do
    state.sideband_mod.send_json(pid, frame)
    state
  end

  defp send_or_queue_control(state, frame),
    do: %{state | pending_control: [frame | state.pending_control]}

  defp schedule_reconnect(state, reason) do
    state =
      if state.notified_disconnect? do
        state
      else
        send(state.parent, {:openai_live_socket, {:disconnected, reason}})
        %{state | notified_disconnect?: true}
      end

    attempt = state.attempt + 1
    delay = reconnect_delay_ms(attempt)
    Process.send_after(self(), :connect, delay)
    %{state | attempt: attempt}
  end

  defp reconnect_delay_ms(attempt) do
    exponent = min(max(attempt, 1) - 1, 10)
    min(@reconnect_base_ms * Integer.pow(2, exponent), @reconnect_max_ms)
  end

  defp teardown(state, opts \\ []) do
    if state.rtp_timer, do: :erlang.cancel_timer(state.rtp_timer)
    if state.jitter_timer, do: Process.cancel_timer(state.jitter_timer)

    if Keyword.get(opts, :close_sideband, true) and is_pid(state.sideband) do
      Process.exit(state.sideband, :normal)
    end

    if is_pid(state.pc) do
      try do
        PeerConnection.close(state.pc)
      catch
        :exit, _ -> :ok
      end
    end

    %{
      state
      | pc: nil,
        track_id: nil,
        session_id: nil,
        sideband: nil,
        sideband_open?: false,
        connected?: false,
        pending_control: [],
        encoder: nil,
        prev_frame: {0, 0},
        in_buffer: <<>>,
        in_queue: :queue.new(),
        in_queued: 0,
        rtp_next: nil,
        rtp_timer: nil,
        jitter: JitterBuffer.new(latency: @jitter_ms),
        jitter_timer: nil,
        decoders: %{},
        hangover: 0
    }
  end

  # -- Outbound Opus RTP pacer (20 ms frames, continuous silence when idle) --

  defp start_rtp_pacer(%{rtp_timer: nil} = state), do: send_rtp_tick(state)
  defp start_rtp_pacer(state), do: state

  defp send_rtp_tick(state) do
    {frame, queue, queued} =
      case :queue.out(state.in_queue) do
        {{:value, pcm}, q} -> {pcm, q, state.in_queued - 1}
        {:empty, q} -> {@silence, q, 0}
      end

    encoder = state.encoder || new_encoder()
    {:ok, payload} = Membrane.Opus.Encoder.Native.encode_packet(encoder, frame, @frame_samples)
    timestamp = rem(state.timestamp + @frame_samples, 4_294_967_296)

    packet =
      ExRTP.Packet.new(payload,
        sequence_number: state.seq,
        timestamp: timestamp,
        marker: state.spurt
      )

    PeerConnection.send_rtp(state.pc, state.track_id, packet)

    now = System.monotonic_time(:millisecond)
    next = if state.rtp_next, do: state.rtp_next + @frame_ms, else: now + @frame_ms
    next = if next < now - @max_lag_ms, do: now + @frame_ms, else: next
    timer = :erlang.start_timer(next, self(), :rtp_tick, abs: true)

    %{
      state
      | encoder: encoder,
        seq: rem(state.seq + 1, 65_536),
        timestamp: timestamp,
        spurt: false,
        in_queue: queue,
        in_queued: queued,
        rtp_next: next,
        rtp_timer: timer
    }
  end

  # VoIP application, automatic bitrate, voice signal (matches Octoroom.Outlet).
  defp new_encoder, do: Membrane.Opus.Encoder.Native.create(48_000, 2, 2048, -1000, 3001)

  defp split_frames(<<frame::binary-size(@frame_bytes), rest::binary>>, acc),
    do: split_frames(rest, [frame | acc])

  defp split_frames(rest, acc), do: {Enum.reverse(acc), rest}

  defp enqueue_frames(queue, queued, []), do: {queue, queued}

  defp enqueue_frames(queue, queued, [frame | rest]) do
    {queue, queued} =
      if queued >= @max_queued_frames do
        {{:value, _dropped}, q} = :queue.out(queue)
        {:queue.in(frame, q), queued}
      else
        {:queue.in(frame, queue), queued + 1}
      end

    enqueue_frames(queue, queued, rest)
  end

  # -- Inbound Opus RTP decoder (24 kHz mono PCM16 + silence gate) --

  defp decode_packets(state, packets) do
    Enum.reduce(packets, state, fn packet, state ->
      case packet.payload do
        <<>> -> state
        payload -> decode_packet(state, payload)
      end
    end)
  end

  # The Opus TOC byte's `s` bit indicates stereo vs mono.
  defp decode_packet(state, <<_config::5, stereo::1, _::2, _::binary>> = payload) do
    channels = stereo + 1

    decoder =
      Map.get_lazy(state.decoders, channels, fn ->
        Membrane.Opus.Decoder.Native.create(@out_rate, channels)
      end)

    state = put_in(state.decoders[channels], decoder)

    try do
      pcm = Membrane.Opus.Decoder.Native.decode_packet(decoder, payload)
      mono = Audio.rechannel(pcm, channels, 1)
      forward_speech(state, mono)
    catch
      _kind, _reason -> state
    end
  end

  defp forward_speech(state, <<>>), do: state

  defp forward_speech(state, pcm) do
    cond do
      PCM16.peak_abs(pcm) >= @silence_threshold ->
        send(state.parent, {:openai_live_socket, {:audio, pcm, sample_rate: @out_rate}})
        %{state | hangover: @hangover_frames}

      state.hangover > 0 ->
        send(state.parent, {:openai_live_socket, {:audio, pcm, sample_rate: @out_rate}})
        %{state | hangover: state.hangover - 1}

      true ->
        state
    end
  end

  defp set_jitter_timer(state, nil), do: state

  defp set_jitter_timer(state, ms) do
    if state.jitter_timer, do: Process.cancel_timer(state.jitter_timer)
    %{state | jitter_timer: Process.send_after(self(), :jitter_timeout, ms)}
  end
end
