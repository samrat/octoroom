defmodule Octoroom.Agent.Pipeline.Spec do
  @moduledoc """
  Builds a pipeline spec with `|>`:

      import Octoroom.Agent.Pipeline.Spec

      processor(:vad, Octoroom.Agent.VAD.Silero)
      |> processor(:turns, MyApp.Turns, threshold: 0.5)
      |> processor(:llm, MyApp.LLM, model: "google:gemini-3.5-flash")

  A spec is a plain value: a chain of named stages. The editing helpers
  (`insert_after/3`, `insert_before/3`, `replace/3`, `remove/2`) find stages
  by name, so a default spec can be changed without rewriting it.

  A stage's name defaults to its module. Names must be unique.
  """

  defmodule Stage do
    @moduledoc false
    @enforce_keys [:name, :module]
    defstruct [:name, :module, opts: []]

    # `isolate: true` (its own process) comes with `Pipeline.Isolated` in
    # phase 3. Until then the option is accepted and ignored.
    def resolve(%__MODULE__{opts: opts} = stage),
      do: %{stage | opts: Keyword.delete(opts, :isolate)}
  end

  defstruct stages: []

  @type name :: atom()
  @type t :: %__MODULE__{stages: [%Stage{}]}

  @doc "An empty spec."
  def new, do: %__MODULE__{}

  @doc """
  Adds a stage to the end of a spec.

  Accepts, optionally after a spec to pipe into: `module`, `name, module`,
  `module, opts`, or `name, module, opts`.
  """
  def processor(a), do: build([a])
  def processor(a, b), do: build([a, b])
  def processor(a, b, c), do: build([a, b, c])
  def processor(a, b, c, d), do: build([a, b, c, d])

  defp build([%__MODULE__{} = spec | args]), do: append(spec, stage(args))
  defp build(args), do: append(new(), stage(args))

  defp stage([module]), do: stage([module, module, []])

  defp stage([a, b]) when is_list(b), do: stage([a, a, b])
  defp stage([a, b]), do: stage([a, b, []])

  defp stage([name, module, opts]) when is_atom(name) and is_atom(module) and is_list(opts) do
    unless module_name?(module) do
      raise ArgumentError, "expected a processor module, got: #{inspect(module)}"
    end

    %Stage{name: name, module: module, opts: opts}
  end

  defp stage(args) do
    raise ArgumentError, "invalid processor arguments: #{inspect(args)}"
  end

  defp module_name?(atom), do: match?("Elixir." <> _, Atom.to_string(atom))

  defp append(%__MODULE__{stages: stages} = spec, stage), do: %{spec | stages: stages ++ [stage]}

  @doc """
  The usual pipeline of an agent, in two parts: `{front_end, back_end}`.
  Each input runs its own front end, and their turns go into one back end:

      front: vad -> stt -> turns
      back:  context -> llm -> tools -> chunker -> tts -> collector

  It picks no provider and no model: `:stt`, `:llm` and `:tts` are needed,
  each naming both. Options are their stage's, passed on as they are:

    * `:stt` - `Octoroom.Agent.Processors.STT`'s
    * `:llm` - `Octoroom.Agent.Processors.LLM`'s
    * `:tts` - `Octoroom.Agent.Processors.TTS`'s
    * `:vad` - `Octoroom.Agent.Processors.VAD`'s (the local Silero model).
      `false` leaves the VAD out: turn taking and barge-in fall back to the
      STT provider.

  `:stt` and `:tts` also take just a `"provider:model"` string.

      Spec.default(
        stt: "soniox:stt-rt-v6",
        llm: [provider: :google, model: "gemini-3.5-flash", reasoning_effort: :minimal],
        tts: [provider: :assembly_ai, model: "assemblyai-tts-1", voice: "aai-titus"]
      )

  With `stt: false` (half-cascaded) the LLM hears each turn as audio, so it
  must be a Gemini model, the VAD can't be left out, and `:transcriber`
  (`Octoroom.Agent.Processors.Transcriber`'s options) names the model that
  writes each turn down afterwards:

      front: vad -> turns (AudioTurns, Smart Turn)
      back:  transcriber -> context -> llm -> tools -> chunker -> tts -> collector

  The front end's turn stage doesn't interrupt; the agent decides who may.
  Change either part with the editing helpers.
  """
  def default(opts) do
    alias Octoroom.Agent.Processors
    alias Octoroom.Agent.{STT, TTS}

    opts = Keyword.validate!(opts, [:stt, :llm, :tts, :transcriber, vad: []])
    vad = opts[:vad]
    stt = named!(opts, :stt, &STT.resolve/1)
    tts = named!(opts, :tts, &TTS.resolve/1)
    llm = Keyword.fetch!(opts, :llm)

    named? = llm[:provider] != nil and is_atom(llm[:provider]) and is_binary(llm[:model])

    if not named? and llm[:request] == nil,
      do: raise(ArgumentError, "llm: needs a :provider and a :model, got: #{inspect(llm)}")

    front = if vad, do: processor(:vad, Processors.VAD, vad), else: new()

    {front, back} =
      if stt do
        front =
          front
          |> processor(:stt, Processors.STT, stt)
          |> processor(:turns, Processors.STTTurns, vad: vad != false, interrupt: false)

        {front, new()}
      else
        if vad == false,
          do: raise(ArgumentError, "stt: false needs the VAD: nothing else hears the user")

        transcriber = opts[:transcriber] || []

        if not is_binary(transcriber[:model]) and transcriber[:transcribe] == nil,
          do: raise(ArgumentError, "stt: false needs transcriber: [model: ...]")

        turns = [interrupt: false] ++ Keyword.take(vad, [:min_speech_ms])

        {processor(front, :turns, Processors.AudioTurns, turns),
         processor(:transcriber, Processors.Transcriber, transcriber)}
      end

    back =
      back
      |> processor(:context, Processors.Context)
      |> processor(:llm, Processors.LLM, llm)
      |> processor(:tools, Processors.Tools)
      |> processor(:chunker, Processors.TextChunker)
      |> processor(:tts, Processors.TTS, tts)
      |> processor(:collector, Processors.AssistantCollector)

    {front, back}
  end

  # A speech stage's options, checked now: a missing provider or model
  # would otherwise only show when someone joins.
  defp named!(opts, key, resolve) do
    case Keyword.fetch(opts, key) do
      {:ok, false} when key == :stt ->
        false

      {:ok, value} ->
        stage_opts =
          if is_list(value),
            do: value,
            else: Octoroom.Agent.SpeechProvider.with_provider(value, [])

        case resolve.(stage_opts) do
          {:ok, _module, _opts} ->
            stage_opts

          {:error, reason} ->
            raise ArgumentError,
                  "#{key}: needs a provider and a model, such as \"provider:model\" " <>
                    "(#{inspect(reason)}), got: #{inspect(value)}"
        end

      :error ->
        raise ArgumentError, "#{key}: is needed: Spec.default/1 picks no provider"
    end
  end

  @doc """
  The pipeline of a Gemini Live agent: no front end (the agent mixes its
  inputs) and one `:gemini` stage, `Octoroom.Agent.Processors.GeminiLive`,
  which takes `opts`: `:model` (needed), `:voice`, `:api_key`,
  `:context_window_compression` (`false` or `[trigger_tokens: ..., target_tokens: ...]`),
  `:input_audio_transcription`, `:output_audio_transcription`, and
  `:response_modalities`.

      Spec.gemini_live(
        model: "gemini-3.8-live",
        voice: "Puck",
        context_window_compression: [trigger_tokens: 24_000, target_tokens: 12_000]
      )
  """
  def gemini_live(opts) do
    if not is_binary(opts[:model]), do: raise(ArgumentError, "gemini_live needs a :model")

    if Keyword.has_key?(opts, :context_window_compression) do
      Octoroom.Agent.GeminiLive.Protocol.context_window_compression(
        opts[:context_window_compression]
      )
    end

    {nil, processor(:gemini, Octoroom.Agent.Processors.GeminiLive, opts)}
  end

  @doc """
  The pipeline of an OpenAI Live agent: no front end (the agent mixes its
  inputs) and one `:openai` stage, `Octoroom.Agent.Processors.OpenAILive`,
  which takes `opts`: `:model` (needed, such as `"gpt-live-1.1"`), `:voice`
  (default `"marin"`), `:api_key` (default `OPENAI_API_KEY`), `:transport`
  (`:webrtc`, the default, or `:websocket`), `:sample_rate` (`24_000` default,
  or `16_000`; WebSocket only), `:delegation` (`:client`,
  `[model: "...", ...]`, or a delegation map), `:idle_timeout_s` (`5..60`
  seconds before standby, or `nil`; WebRTC only), `:wake_policy` (`:speech` or
  `[type: :speech, vad_threshold: 0.5]`; WebRTC only), and `:initial_items`.

      Spec.openai_live(
        model: "gpt-live-1.1",
        voice: "marin",
        delegation: [model: "gpt-5.4-mini"],
        idle_timeout_s: 15,
        wake_policy: [type: :speech, vad_threshold: 0.5]
      )
  """
  def openai_live(opts) do
    alias Octoroom.Agent.OpenAILive.Protocol

    if not is_binary(opts[:model]), do: raise(ArgumentError, "openai_live needs a :model")

    transport = Protocol.transport(Keyword.get(opts, :transport, Protocol.default_transport()))

    if Keyword.has_key?(opts, :sample_rate) do
      Protocol.sample_rate(opts[:sample_rate])
    end

    if Keyword.has_key?(opts, :delegation) do
      Protocol.delegation(opts[:delegation])
    end

    idle_timeout_s =
      if Keyword.has_key?(opts, :idle_timeout_s),
        do: Protocol.idle_timeout_s(opts[:idle_timeout_s])

    wake_policy =
      if Keyword.has_key?(opts, :wake_policy),
        do: Protocol.wake_policy(opts[:wake_policy])

    if transport == :websocket and (idle_timeout_s != nil or wake_policy != nil) do
      raise ArgumentError, "idle_timeout_s and wake_policy require transport: :webrtc"
    end

    {nil, processor(:openai, Octoroom.Agent.Processors.OpenAILive, opts)}
  end

  @doc "The options of the stage named `name`, or nil when there's none."
  def opts(%__MODULE__{stages: stages}, name) do
    Enum.find_value(stages, fn stage -> if stage.name == name, do: stage.opts end)
  end

  @doc "Names of the stages, in order."
  def names(%__MODULE__{stages: stages}), do: Enum.map(stages, & &1.name)

  @doc "Inserts the stages of `insert` right after the stage `name`."
  def insert_after(%__MODULE__{} = spec, name, %__MODULE__{} = insert),
    do: splice(spec, name, fn stage -> [stage | insert.stages] end)

  @doc "Inserts the stages of `insert` right before the stage `name`."
  def insert_before(%__MODULE__{} = spec, name, %__MODULE__{} = insert),
    do: splice(spec, name, fn stage -> insert.stages ++ [stage] end)

  @doc "Replaces the stage `name` with the stages of `replacement`."
  def replace(%__MODULE__{} = spec, name, %__MODULE__{} = replacement),
    do: splice(spec, name, fn _stage -> replacement.stages end)

  @doc "Removes the stage `name`."
  def remove(%__MODULE__{} = spec, name), do: splice(spec, name, fn _stage -> [] end)

  defp splice(%__MODULE__{stages: stages} = spec, name, fun) do
    case Enum.find_index(stages, &(&1.name == name)) do
      nil ->
        raise ArgumentError, "no stage named #{inspect(name)} in #{inspect(names(spec))}"

      index ->
        {before, [stage | rest]} = Enum.split(stages, index)
        %{spec | stages: before ++ fun.(stage) ++ rest}
    end
  end

  @doc """
  Checks that the spec has at least one stage, that names are unique, and
  that every module implements `Octoroom.Agent.Processor`.
  """
  def validate(%__MODULE__{stages: []}), do: {:error, :empty_pipeline}

  def validate(%__MODULE__{stages: stages} = spec) do
    with :ok <- unique_names(stages),
         :ok <- processor_modules(stages) do
      {:ok, spec}
    end
  end

  defp unique_names(stages) do
    case stages |> Enum.frequencies_by(& &1.name) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_names, Enum.map(duplicates, &elem(&1, 0))}}
    end
  end

  defp processor_modules(stages) do
    Enum.find_value(stages, :ok, fn %Stage{name: name, module: module, opts: opts} ->
      if Code.ensure_loaded?(module) and function_exported?(module, :handle_frame, 3) do
        validate_options(name, module, opts)
      else
        {:error, {:not_a_processor, name, module}}
      end
    end)
  end

  # A processor may declare `options_schema/0` (a NimbleOptions schema). The
  # `isolate` option belongs to the runner, not the processor.
  defp validate_options(name, module, opts) do
    if function_exported?(module, :options_schema, 0) do
      case NimbleOptions.validate(Keyword.delete(opts, :isolate), module.options_schema()) do
        {:ok, _opts} -> nil
        {:error, error} -> {:error, {:invalid_options, name, Exception.message(error)}}
      end
    end
  end
end
