defmodule Octoroom.Agent.Processors.TTS do
  @moduledoc """
  Speaks `Text` frames.

  For each chunk it pushes `TTSStarted` (first chunk of a response),
  `TTSText`, `OutputAudio` as the audio streams in, and `TTSStopped` when the
  response is done. Chunks that arrive while one is synthesizing are queued
  and sent as one request, so the voice keeps its prosody across sentences.
  `LLMResponseEnd` and `End` wait until the queued audio is out.

  Options: `:provider` (`:inworld`, `:openai`, `:woof`), `:model`, `:voice`,
  `:stream`, `:audio_encoding`, `:output_sample_rate`, `:delivery_mode`,
  `:timestamp_transport_strategy`, `:model_path`, `:token` (defaults to the
  provider's environment variable), `:chunk_timeout_ms`, and `:synthesize`,
  a `fn text, on_audio -> :ok | {:error, reason} end` that replaces the
  provider (for tests).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Cascaded.TextToSpeech
  alias Octoroom.Agent.Frames

  @chunk_timeout_ms 15_000

  @impl true
  def init(opts, _ctx) do
    opts = Map.new(opts)
    provider = Map.get(opts, :provider, :inworld)

    {:ok,
     %{
       synthesize: Map.get(opts, :synthesize) || provider_synthesize(provider, opts),
       chunk_timeout_ms: Map.get(opts, :chunk_timeout_ms, @chunk_timeout_ms),
       speaking?: false,
       started?: false,
       queue: [],
       held: []
     }}
  end

  defp provider_synthesize(provider, opts) do
    token = Map.get(opts, :token) || provider_token(provider)

    fn text, on_audio ->
      TextToSpeech.stream_speech(
        provider: provider,
        token: token,
        model: Map.get(opts, :model),
        voice: Map.get(opts, :voice),
        model_path: Map.get(opts, :model_path),
        input: text,
        stream: Map.get(opts, :stream, false),
        audio_encoding: Map.get(opts, :audio_encoding, "LINEAR16"),
        sample_rate: Map.get(opts, :output_sample_rate, 24_000),
        delivery_mode: Map.get(opts, :delivery_mode),
        timestamp_transport_strategy: Map.get(opts, :timestamp_transport_strategy),
        on_audio: on_audio
      )
    end
  end

  defp provider_token(:inworld), do: System.get_env("INWORLD_API_KEY")
  defp provider_token(:openai), do: System.get_env("OPENAI_API_KEY")
  defp provider_token(_provider), do: nil

  @impl true
  def handle_frame(%Frames.Text{text: text}, :downstream, state) do
    if String.trim(text) == "" do
      {[], state}
    else
      if state.speaking?,
        do: {[], %{state | queue: state.queue ++ [text]}},
        else: speak(text, state)
    end
  end

  # Response markers wait for the audio before them.
  def handle_frame(%module{} = frame, :downstream, %{speaking?: true} = state)
      when module in [Frames.LLMResponseEnd, Frames.End],
      do: {[], %{state | held: state.held ++ [frame]}}

  def handle_frame(%Frames.LLMResponseEnd{} = frame, :downstream, state),
    do: {stopped(state) ++ [{:push, frame, :downstream}], %{state | started?: false}}

  def handle_frame(%Frames.Interruption{}, _direction, state) do
    {[{:cancel_timer, :chunk_timeout}],
     %{state | speaking?: false, started?: false, queue: [], held: []}}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_async(:speak, {:audio, audio}, state) when is_binary(audio) and audio != "",
    do: {[{:push, %Frames.OutputAudio{audio: audio}, :downstream}], state}

  def handle_async(:speak, {:done, :ok}, state), do: finish_chunk(state, [])

  def handle_async(:speak, {:done, {:error, reason}}, state), do: chunk_failed(reason, state)
  def handle_async(:speak, {:failed, reason}, state), do: chunk_failed(reason, state)
  def handle_async(_key, _message, state), do: {[], state}

  @impl true
  def handle_timer(:chunk_timeout, %{speaking?: true} = state) do
    {effects, state} = chunk_failed(:tts_chunk_timeout, state)
    {[{:cancel, :speak} | effects], state}
  end

  def handle_timer(_key, state), do: {[], state}

  defp speak(text, state) do
    synthesize = state.synthesize

    task = fn emit ->
      synthesize.(text, fn
        audio when is_binary(audio) and audio != "" -> emit.({:audio, audio})
        _other -> :ok
      end)
    end

    started = if state.started?, do: [], else: [{:push, %Frames.TTSStarted{}, :downstream}]

    {started ++
       [
         {:push, %Frames.TTSText{text: text}, :downstream},
         {:async, :speak, task},
         {:timer, :chunk_timeout, state.chunk_timeout_ms}
       ], %{state | speaking?: true, started?: true}}
  end

  defp chunk_failed(reason, state) do
    Logger.warning("TTS chunk failed: #{inspect(reason)}")
    finish_chunk(state, [{:error, reason, false}])
  end

  # Speaks what queued up meanwhile, or releases the held markers.
  defp finish_chunk(%{queue: []} = state, effects) do
    state = %{state | speaking?: false}
    {released, state} = release(state.held, %{state | held: []})
    {[{:cancel_timer, :chunk_timeout} | effects] ++ released, state}
  end

  defp finish_chunk(%{queue: queue} = state, effects) do
    {more, state} = speak(Enum.join(queue, " "), %{state | queue: [], speaking?: false})
    {effects ++ more, state}
  end

  defp release(held, state) do
    Enum.reduce(held, {[], state}, fn
      %Frames.LLMResponseEnd{} = frame, {effects, state} ->
        {effects ++ stopped(state) ++ [{:push, frame, :downstream}], %{state | started?: false}}

      frame, {effects, state} ->
        {effects ++ [{:push, frame, :downstream}], state}
    end)
  end

  defp stopped(%{started?: true}), do: [{:push, %Frames.TTSStopped{}, :downstream}]
  defp stopped(_state), do: []
end
