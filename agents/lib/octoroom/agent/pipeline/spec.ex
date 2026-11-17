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
  The default cascaded pipeline for a `Octoroom.Agent.Backend.Cascaded` config:

      vad -> stt -> turns -> context -> llm -> tools -> chunker -> tts -> collector

  Without the VAD, turn taking and barge-in fall back to the STT provider.

  Options: `:context` (options for the context stage, such as
  `instructions:`).
  """
  def cascaded(%Octoroom.Agent.Backend.Cascaded{} = backend, opts \\ []) do
    alias Octoroom.Agent.Processors

    cond do
      Octoroom.Agent.Backend.Cascaded.audio_input?(backend) ->
        raise ArgumentError, "audio input to the LLM (speech_to_text: false) isn't copied yet"

      Map.get(backend.turn_detection, :provider) != :stt ->
        raise ArgumentError, "only turn_detection: :stt is copied so far"

      true ->
        :ok
    end

    vad = backend.vad
    vad? = Map.get(vad, :enabled, true)

    vad_opts =
      vad
      |> Map.take([
        :start_threshold,
        :stop_threshold,
        :min_speech_ms,
        :min_silence_ms,
        :model_path
      ])
      |> Map.to_list()

    spec = if vad?, do: processor(:vad, Processors.VAD, vad_opts), else: new()

    spec
    |> processor(:stt, Processors.STT, Map.to_list(backend.speech_to_text))
    |> processor(:turns, Processors.STTTurns, vad: vad?)
    |> processor(:context, Processors.Context, Keyword.get(opts, :context, []))
    |> processor(:llm, Processors.LLM, Map.to_list(backend.llm))
    |> processor(:tools, Processors.Tools)
    |> processor(:chunker, Processors.TextChunker)
    |> processor(:tts, Processors.TTS, Map.to_list(backend.text_to_speech))
    |> processor(:collector, Processors.AssistantCollector)
  end

  @doc """
  The pipeline of an agent that hears several people, in two parts:
  `{front_end, back_end}`. Each input runs its own front end, and their
  turns go into one back end.

  With speech-to-text (cascaded):

      front: vad -> stt -> turns [-> decisions]
      back:  context -> llm -> tools -> chunker -> tts -> collector

  With `speech_to_text: false` (half-cascaded: the LLM hears each turn):

      front: vad -> turns (AudioTurns, Smart Turn) [-> decisions]
      back:  transcriber -> context -> llm -> tools -> chunker -> tts -> collector

  The front ends' turn stages don't interrupt; the agent decides who may.

  Options: `:decisions` (options for `Processors.Decisions`; leave it out
  for no decision stage), `:context`.
  """
  def cascaded_split(%Octoroom.Agent.Backend.Cascaded{} = backend, opts \\ []) do
    alias Octoroom.Agent.Processors

    audio? = Octoroom.Agent.Backend.Cascaded.audio_input?(backend)
    vad = backend.vad
    vad? = audio? or Map.get(vad, :enabled, true)

    if not audio? and Map.get(backend.turn_detection, :provider) != :stt,
      do: raise(ArgumentError, "with speech-to-text, only turn_detection: :stt is copied so far")

    vad_opts =
      vad
      |> Map.take([
        :start_threshold,
        :stop_threshold,
        :min_speech_ms,
        :min_silence_ms,
        :model_path
      ])
      |> Map.to_list()

    front = if vad?, do: processor(:vad, Processors.VAD, vad_opts), else: new()

    front =
      if audio? do
        smart = backend.turn_detection |> Map.drop([:provider]) |> Map.to_list()

        processor(
          front,
          :turns,
          Processors.AudioTurns,
          [interrupt: false, smart_turn: Map.get(backend.turn_detection, :smart_turn, true)] ++
            Keyword.take(smart, [:threshold, :max_silence_ms, :model_path, :features_model_path]) ++
            [min_speech_ms: Map.get(vad, :min_speech_ms, 200)]
        )
      else
        front
        |> processor(:stt, Processors.STT, Map.to_list(backend.speech_to_text))
        |> processor(:turns, Processors.STTTurns, vad: vad?, interrupt: false)
      end

    front =
      case Keyword.fetch(opts, :decisions) do
        {:ok, decision_opts} -> processor(front, :decisions, Processors.Decisions, decision_opts)
        :error -> front
      end

    transcription_model = Map.get(backend.speech_to_text, :transcription_model)

    back =
      if audio? and is_binary(transcription_model) and transcription_model != "",
        do: processor(:transcriber, Processors.Transcriber, model: transcription_model),
        else: new()

    back =
      back
      |> processor(:context, Processors.Context, Keyword.get(opts, :context, []))
      |> processor(:llm, Processors.LLM, Map.to_list(backend.llm))
      |> processor(:tools, Processors.Tools)
      |> processor(:chunker, Processors.TextChunker)
      |> processor(:tts, Processors.TTS, Map.to_list(backend.text_to_speech))
      |> processor(:collector, Processors.AssistantCollector)

    {front, back}
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
      cond do
        not (Code.ensure_loaded?(module) and function_exported?(module, :handle_frame, 3)) ->
          {:error, {:not_a_processor, name, module}}

        true ->
          validate_options(name, module, opts)
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
