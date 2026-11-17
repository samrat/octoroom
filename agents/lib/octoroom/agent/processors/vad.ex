defmodule Octoroom.Agent.Processors.VAD do
  @moduledoc """
  Local voice activity detection with Silero.

  `InputAudio` passes through; `VADUserStartedSpeaking` and
  `VADUserStoppedSpeaking` follow it when speech starts or stops. The stop
  comes `min_silence_ms` after the user stopped talking.

  Options: `:start_threshold`, `:stop_threshold`, `:min_speech_ms`,
  `:min_silence_ms`, `:model_path`. Inference runs inline; use
  `isolate: true` to give it its own process. With `analyzer: :none`, no
  model loads and the stage passes audio through (for tests).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.VAD

  @machine_keys [:start_threshold, :stop_threshold, :min_speech_ms, :min_silence_ms]

  @impl true
  def init(opts, _ctx) do
    machine =
      opts
      |> Keyword.take(@machine_keys)
      |> Map.new()
      |> Map.put(:frame_ms, VAD.Silero.frame_ms())
      |> VAD.new()

    case Keyword.get(opts, :analyzer) do
      :none ->
        {:ok, %{analyzer: nil, machine: machine}}

      nil ->
        case VAD.Silero.new(model_path: Keyword.get(opts, :model_path)) do
          {:ok, analyzer} -> {:ok, %{analyzer: analyzer, machine: machine}}
          {:error, reason} -> {:error, {:vad_unavailable, reason}}
        end
    end
  end

  @impl true
  def handle_frame(
        %Frames.InputAudio{audio: audio} = frame,
        :downstream,
        %{analyzer: nil} = state
      )
      when is_binary(audio),
      do: {[{:push, frame, :downstream}], state}

  def handle_frame(%Frames.InputAudio{audio: audio} = frame, :downstream, state) do
    {probabilities, analyzer} = VAD.Silero.process(state.analyzer, audio)
    {events, machine} = VAD.process_all(state.machine, probabilities)

    {[{:push, frame, :downstream} | Enum.flat_map(events, &event(&1, frame.source))],
     %{state | analyzer: analyzer, machine: machine}}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  defp event(:speech_started, source) do
    [
      {:notify, {:user_speech, :started}},
      {:push, %Frames.VADUserStartedSpeaking{source: source}, :downstream}
    ]
  end

  defp event(:speech_stopped, source) do
    [
      {:notify, {:user_speech, :stopped}},
      {:push, %Frames.VADUserStoppedSpeaking{source: source}, :downstream}
    ]
  end

  @doc "How long after the user stopped talking the stop is reported, in ms."
  def min_silence_ms(opts),
    do: Keyword.get(opts, :min_silence_ms, VAD.defaults() |> Map.fetch!(:min_silence_ms))
end
