defmodule Octoroom.Agent.Processors.TTS do
  @moduledoc """
  Speaks `Text` frames.

  For each chunk it pushes `TTSStarted` (first chunk of a response),
  `TTSText`, `OutputAudio` as the audio streams in, and `TTSStopped` when the
  response is done. Chunks that arrive while one is synthesizing are queued
  and sent as one request, so the voice keeps its prosody across sentences.
  `LLMResponseEnd` and `End` wait until the queued audio is out.

  Options are `Octoroom.Agent.TTS`'s: `:provider` and `:model` (both needed),
  `:voice`, `:api_key` and the provider's own, with
  `:output_sample_rate` as the provider's `:sample_rate`. It connects the
  provider once (`Octoroom.Agent.TTS.connect/2`), for those that keep a
  connection. Also
  `:chunk_timeout_ms`, and `:synthesize`, a
  `fn text, on_audio -> :ok | {:error, reason} end` that replaces the
  provider (for tests).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.{Frames, TTS}

  @chunk_timeout_ms 15_000

  @impl true
  def init(opts, _ctx) do
    {synthesize, opts} = Keyword.pop(opts, :synthesize)
    {chunk_timeout_ms, opts} = Keyword.pop(opts, :chunk_timeout_ms, @chunk_timeout_ms)

    with {:ok, synthesize, info} <- synthesizer(synthesize, opts) do
      {:ok,
       %{
         synthesize: synthesize,
         provider: info.provider,
         model: info.model,
         voice: info.voice,
         chunk_timeout_ms: chunk_timeout_ms,
         speaking?: false,
         started?: false,
         queue: [],
         held: []
       }}
    end
  end

  defp synthesizer(synthesize, opts) when is_function(synthesize, 2),
    do: {:ok, synthesize, %{provider: nil, model: opts[:model], voice: opts[:voice]}}

  defp synthesizer(nil, opts) do
    {rate, opts} = Keyword.pop(opts, :output_sample_rate)
    opts = put_present(opts, :sample_rate, rate)

    with {:ok, module, opts} <- TTS.resolve(opts),
         {:ok, opts} <- TTS.connect(module, opts) do
      info = %{
        provider: provider_name(module),
        model: Keyword.get(opts, :model),
        voice: Keyword.get(opts, :voice)
      }

      {:ok, fn text, on_audio -> TTS.stream_with(module, text, on_audio, opts) end, info}
    end
  end

  defp provider_name(module) do
    Enum.find_value(TTS.providers(), module, fn {name, provider} ->
      if provider == module, do: name
    end)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

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

    meta = %{
      provider: state.provider,
      model: state.model,
      voice: state.voice,
      chars: String.length(text)
    }

    {started ++
       [
         {:push, %Frames.TTSText{text: text}, :downstream},
         {:async, :speak, task, meta},
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
