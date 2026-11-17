defmodule Octoroom.Agent.Processors.STT do
  @moduledoc """
  Streaming speech-to-text over Soniox's real-time WebSocket.

  `InputAudio` passes through and is sent to the provider in 100 ms chunks.
  Transcripts come back as `InterimTranscription` and `Transcription`
  frames. A `FinalizeTranscript` frame moving upstream asks the provider to
  finalize what it has heard now.

  Options: `:provider` (`:soniox`, the only one so far), `:api_key`
  (defaults to `SONIOX_API_KEY`), `:sample_rate`, plus the
  provider settings of `Octoroom.Agent.Backend.Cascaded`'s `speech_to_text`. The
  socket starts only under a host (`ctx.runner`); in `Octoroom.Agent.Pipeline.Test`, feed
  provider events with `Test.info/3` (for example `{:soniox_socket, event}`).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Cascaded.SonioxSocket
  alias Octoroom.Agent.Frames

  @min_chunk_ms 50
  @target_chunk_ms 100
  # Audio held while (re)connecting.
  @max_buffer_ms 5_000
  @reconnect_ms [1_000, 2_000, 5_000, 10_000]

  @impl true
  def init(opts, ctx) do
    config = Map.new(opts)
    provider = Map.get(config, :provider, :soniox)
    sample_rate = Map.get(config, :sample_rate, 16_000)

    state = %{
      provider: provider,
      socket_module: socket_module(provider),
      socket: nil,
      connected?: false,
      failed?: false,
      buffer: <<>>,
      # The input the audio came from; transcripts carry it. One socket hears
      # one source.
      source: nil,
      min_chunk_bytes: div(sample_rate * 2 * @min_chunk_ms, 1_000),
      target_chunk_bytes: div(sample_rate * 2 * @target_chunk_ms, 1_000),
      max_buffer_bytes: div(sample_rate * 2 * @max_buffer_ms, 1_000),
      # For reconnecting: the host, the config and key, which attempt this is,
      # and a ref that tells this stage's reconnect messages from others'.
      runner: nil,
      config: config,
      api_key: nil,
      attempt: 0,
      ref: make_ref()
    }

    case ctx do
      %{runner: runner} when is_pid(runner) ->
        with {:ok, api_key} <- api_key(provider, config),
             {:ok, socket} <- start_socket(provider, config, api_key, runner) do
          {:ok, %{state | socket: socket, runner: runner, api_key: api_key}}
        end

      _no_runner ->
        {:ok, state}
    end
  end

  # More providers come over from Subvocal as they're wanted.
  defp socket_module(:soniox), do: SonioxSocket

  defp api_key(:soniox, config) do
    env = "SONIOX_API_KEY"

    case Map.get(config, :api_key) || System.get_env(env) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _missing -> {:error, {:missing_env, env}}
    end
  end

  # Socket events go to the host, which hands unaddressed messages to
  # every processor.
  defp start_socket(:soniox, config, api_key, parent) do
    SonioxSocket.start_link(
      api_key: api_key,
      parent: parent,
      model: Map.get(config, :model, "stt-rt-v5"),
      audio_format: Map.get(config, :audio_format, "pcm_s16le"),
      sample_rate: Map.get(config, :sample_rate, 16_000),
      num_channels: Map.get(config, :num_channels, 1),
      language_hints: Map.get(config, :language_hints),
      enable_endpoint_detection: Map.get(config, :enable_endpoint_detection, true),
      endpoint_latency_adjustment_level: Map.get(config, :endpoint_latency_adjustment_level),
      endpoint_sensitivity: Map.get(config, :endpoint_sensitivity),
      max_endpoint_delay_ms: Map.get(config, :max_endpoint_delay_ms)
    )
  end

  @impl true
  def handle_frame(%Frames.InputAudio{audio: audio} = frame, :downstream, state),
    do: {[{:push, frame, :downstream}], send_audio(%{state | source: frame.source}, audio)}

  def handle_frame(%Frames.FinalizeTranscript{}, :upstream, state) do
    if state.connected?, do: state.socket_module.finalize(state.socket)
    {[], state}
  end

  def handle_frame(%Frames.End{} = frame, :downstream, state) do
    {[{:push, frame, :downstream}], end_session(state)}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  # Events from this stage's own socket: an agent with several inputs runs
  # one STT stage, and one socket, per input in the same process.
  def handle_info({:soniox_socket, socket, event}, %{socket: socket} = state),
    do: event(event, state)

  # Without a socket (`Pipeline.Test`), tests send events with no pid.
  def handle_info({:soniox_socket, event}, %{socket: nil, runner: nil} = state),
    do: event(event, state)

  def handle_info({:octoroom_agent_stt_reconnect, ref}, %{ref: ref, failed?: true} = state) do
    case start_socket(state.provider, state.config, state.api_key, state.runner) do
      {:ok, socket} ->
        {[], %{state | socket: socket, failed?: false, connected?: false}}

      {:error, reason} ->
        Logger.warning(
          "STT reconnect failed provider=#{state.provider} reason=#{inspect(reason)}"
        )

        {[], schedule_reconnect(state)}
    end
  end

  def handle_info(_message, state), do: {[], state}

  @impl true
  def terminate(_reason, %{socket: socket}) when is_pid(socket), do: Process.exit(socket, :normal)
  def terminate(_reason, _state), do: :ok

  defp event(:connected, state) do
    Logger.info("STT_EVENT provider=#{state.provider} event=connected")
    state = %{state | connected?: true, attempt: 0} |> send_audio(<<>>)
    {[{:notify, {:status, "Listening"}}], state}
  end

  defp event({:transcription_final, text}, state) do
    text = String.trim(text || "")
    {[{:push, %Frames.Transcription{text: text, source: state.source}, :downstream}], state}
  end

  defp event({:transcription_partial, text}, state) do
    case String.trim(text || "") do
      "" ->
        {[], state}

      text ->
        frame = %Frames.InterimTranscription{text: text, source: state.source}
        {[{:push, frame, :downstream}], state}
    end
  end

  defp event({:decode_error, reason}, state) do
    Logger.warning("STT decode error provider=#{state.provider} reason=#{inspect(reason)}")
    {[{:notify, {:status, "Voice issue"}}], state}
  end

  defp event({:error, event}, state) do
    Logger.warning("STT error provider=#{state.provider} event=#{inspect(event)}")

    {[
       {:notify, {:transcription, %{status: "error", text: error_text(event)}}},
       {:notify, {:status, "Voice issue"}}
     ], failed(state)}
  end

  defp event(:finished, state), do: {[], state}

  defp event({:disconnected, reason, %{intentional?: true}}, state) do
    Logger.info(
      "STT_EVENT provider=#{state.provider} event=disconnected reason=#{inspect(reason)}"
    )

    {[{:notify, {:status, "Disconnected"}}], %{state | connected?: false}}
  end

  defp event({:disconnected, reason, _info}, state), do: disconnected(reason, state)
  defp event({:disconnected, reason}, state), do: disconnected(reason, state)
  defp event(_other, state), do: {[], state}

  defp disconnected(reason, state) do
    Logger.warning(
      "STT_EVENT provider=#{state.provider} event=disconnected reason=#{inspect(reason)}"
    )

    {[{:notify, {:status, "Disconnected"}}], failed(state)}
  end

  # The socket is done: forget it (late events from it no longer match) and
  # open another after a backoff. Audio until then is held, up to a limit.
  defp failed(state) do
    state = %{state | socket: nil, connected?: false, failed?: true, buffer: <<>>}
    if state.runner, do: schedule_reconnect(state), else: state
  end

  defp schedule_reconnect(state) do
    delay = Enum.at(@reconnect_ms, state.attempt, List.last(@reconnect_ms))
    Process.send_after(state.runner, {:octoroom_agent_stt_reconnect, state.ref}, delay)
    %{state | attempt: state.attempt + 1}
  end

  defp error_text(%{"error_message" => message}) when is_binary(message), do: message
  defp error_text(%{"error_code" => code}) when not is_nil(code), do: "STT error #{code}"
  defp error_text(_event), do: "STT error"

  # Audio is held until the socket connects, then sent in 100 ms chunks.
  # While waiting to reconnect, it's dropped.
  defp send_audio(%{failed?: true} = state, _audio), do: state

  defp send_audio(%{connected?: false} = state, audio) do
    buffer = state.buffer <> audio
    over = byte_size(buffer) - state.max_buffer_bytes
    buffer = if over > 0, do: binary_part(buffer, over, state.max_buffer_bytes), else: buffer
    %{state | buffer: buffer}
  end

  defp send_audio(state, audio) do
    {chunks, rest} = split(state.buffer <> audio, state.target_chunk_bytes)
    Enum.each(chunks, &state.socket_module.send_audio(state.socket, &1))
    %{state | buffer: rest}
  end

  defp end_session(%{connected?: true} = state) do
    {chunks, rest} = split(state.buffer, state.target_chunk_bytes)
    chunks = if byte_size(rest) >= state.min_chunk_bytes, do: chunks ++ [rest], else: chunks
    Enum.each(chunks, &state.socket_module.send_audio(state.socket, &1))
    state.socket_module.terminate_session(state.socket)
    %{state | buffer: <<>>}
  end

  defp end_session(state), do: state

  defp split(audio, size) when byte_size(audio) < size, do: {[], audio}

  defp split(audio, size) do
    <<chunk::binary-size(size), rest::binary>> = audio
    {chunks, remainder} = split(rest, size)
    {[chunk | chunks], remainder}
  end
end
