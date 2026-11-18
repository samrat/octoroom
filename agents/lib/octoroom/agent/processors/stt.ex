defmodule Octoroom.Agent.Processors.STT do
  @moduledoc """
  Streaming speech-to-text through an `Octoroom.Agent.STT` provider.

  `InputAudio` passes through and is sent to the provider in 100 ms chunks.
  Transcripts come back as `InterimTranscription` and `Transcription`
  frames. A `FinalizeTranscript` frame moving upstream asks the provider to
  finalize what it has heard now. A failed session is replaced after a
  backoff.

  Options are `Octoroom.Agent.STT`'s: `:provider` (default `:soniox`),
  `:model`, `:api_key`, `:sample_rate` and the provider's own, as in
  `Octoroom.Agent.Backend.Cascaded`'s `speech_to_text`. The session starts
  only under a host (`ctx.runner`); in `Octoroom.Agent.Pipeline.Test`, feed
  provider events with `Test.info/3` (for example `{:stt, {:final, "Hi"}}`).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.{Frames, STT}

  @min_chunk_ms 50
  @target_chunk_ms 100
  # Audio held while (re)connecting.
  @max_buffer_ms 5_000
  @reconnect_ms [1_000, 2_000, 5_000, 10_000]

  @impl true
  def init(opts, ctx) do
    with {:ok, module, provider_opts} <- STT.resolve(Keyword.put_new(opts, :provider, :soniox)) do
      sample_rate = Keyword.fetch!(provider_opts, :sample_rate)

      state = %{
        provider: provider_name(module),
        module: module,
        provider_opts: provider_opts,
        socket: nil,
        connected?: false,
        failed?: false,
        buffer: <<>>,
        # The input the audio came from; transcripts carry it. One session
        # hears one source.
        source: nil,
        min_chunk_bytes: div(sample_rate * 2 * @min_chunk_ms, 1_000),
        target_chunk_bytes: div(sample_rate * 2 * @target_chunk_ms, 1_000),
        max_buffer_bytes: div(sample_rate * 2 * @max_buffer_ms, 1_000),
        # For reconnecting: the host, which attempt this is, and a ref that
        # tells this stage's reconnect messages from others'.
        runner: nil,
        attempt: 0,
        ref: make_ref()
      }

      case ctx do
        %{runner: runner} when is_pid(runner) ->
          state = %{state | runner: runner}
          with {:ok, socket} <- start_socket(state), do: {:ok, %{state | socket: socket}}

        _no_runner ->
          {:ok, state}
      end
    end
  end

  # Events go to the host, which hands unaddressed messages to every
  # processor.
  defp start_socket(state),
    do: state.module.start_link(Keyword.put(state.provider_opts, :owner, state.runner))

  defp provider_name(module) do
    Enum.find_value(STT.providers(), inspect(module), fn {name, provider} ->
      if provider == module, do: name
    end)
  end

  @impl true
  def handle_frame(%Frames.InputAudio{audio: audio} = frame, :downstream, state),
    do: {[{:push, frame, :downstream}], send_audio(%{state | source: frame.source}, audio)}

  def handle_frame(%Frames.FinalizeTranscript{}, :upstream, state) do
    if state.connected?, do: STT.finalize(state.module, state.socket)
    {[], state}
  end

  def handle_frame(%Frames.End{} = frame, :downstream, state) do
    {[{:push, frame, :downstream}], end_session(state)}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  # Events from this stage's own session: an agent with several inputs runs
  # one STT stage, and one session, per input in the same process.
  def handle_info({:stt, socket, event}, %{socket: socket} = state) when is_pid(socket),
    do: event(event, state)

  # Without a session (`Pipeline.Test`), tests send events with no pid.
  def handle_info({:stt, event}, %{socket: nil, runner: nil} = state),
    do: event(event, state)

  def handle_info({:octoroom_agent_stt_reconnect, ref}, %{ref: ref, failed?: true} = state) do
    case start_socket(state) do
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

  defp event({:final, text}, state) do
    text = String.trim(text || "")
    {[{:push, %Frames.Transcription{text: text, source: state.source}, :downstream}], state}
  end

  defp event({:partial, text}, state) do
    case String.trim(text || "") do
      "" ->
        {[], state}

      text ->
        frame = %Frames.InterimTranscription{text: text, source: state.source}
        {[{:push, frame, :downstream}], state}
    end
  end

  defp event({:warning, reason}, state) do
    Logger.warning("STT warning provider=#{state.provider} reason=#{inspect(reason)}")
    {[{:notify, {:status, "Voice issue"}}], state}
  end

  defp event({:error, reason}, state) do
    Logger.warning("STT error provider=#{state.provider} reason=#{inspect(reason)}")

    {[
       {:notify, {:transcription, %{status: "error", text: STT.error_message(reason)}}},
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
    Enum.each(chunks, &state.module.send_audio(state.socket, &1))
    %{state | buffer: rest}
  end

  defp end_session(%{connected?: true} = state) do
    {chunks, rest} = split(state.buffer, state.target_chunk_bytes)
    chunks = if byte_size(rest) >= state.min_chunk_bytes, do: chunks ++ [rest], else: chunks
    Enum.each(chunks, &state.module.send_audio(state.socket, &1))
    state.module.close(state.socket)
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
