defmodule Octoroom.Agent.VAD do
  @moduledoc """
  Voice activity state machine.

  Turns a stream of per-frame speech probabilities (from `Octoroom.Agent.VAD.Silero`
  or any other analyzer) into `:speech_started` / `:speech_stopped` events using
  hysteresis:

    * speech starts once probabilities stay at or above `start_threshold` for
      `min_speech_ms`
    * speech stops once probabilities stay below `stop_threshold` for
      `min_silence_ms`

  Probabilities between the two thresholds keep the current state.
  """

  @default_frame_ms 32

  @defaults %{
    start_threshold: 0.5,
    stop_threshold: 0.35,
    min_speech_ms: 200,
    min_silence_ms: 300
  }

  defstruct speaking?: false,
            run_ms: 0,
            frame_ms: @default_frame_ms,
            start_threshold: @defaults.start_threshold,
            stop_threshold: @defaults.stop_threshold,
            min_speech_ms: @defaults.min_speech_ms,
            min_silence_ms: @defaults.min_silence_ms

  @type event :: :speech_started | :speech_stopped
  @type t :: %__MODULE__{}

  def defaults, do: @defaults

  @doc """
  Builds a state machine. Accepts a map or keyword list with any of the default
  keys plus `:frame_ms` (the duration covered by each probability).
  """
  def new(opts \\ %{}) do
    opts = Map.new(opts)

    %__MODULE__{
      frame_ms: Map.get(opts, :frame_ms, @default_frame_ms),
      start_threshold: Map.get(opts, :start_threshold, @defaults.start_threshold),
      stop_threshold: Map.get(opts, :stop_threshold, @defaults.stop_threshold),
      min_speech_ms: Map.get(opts, :min_speech_ms, @defaults.min_speech_ms),
      min_silence_ms: Map.get(opts, :min_silence_ms, @defaults.min_silence_ms)
    }
  end

  @doc "Feeds one frame probability. Returns the events it triggered."
  @spec process(t(), number()) :: {[event()], t()}
  def process(%__MODULE__{speaking?: false} = vad, probability) do
    if probability >= vad.start_threshold do
      advance(vad, vad.min_speech_ms, :speech_started, true)
    else
      {[], %{vad | run_ms: 0}}
    end
  end

  def process(%__MODULE__{speaking?: true} = vad, probability) do
    if probability < vad.stop_threshold do
      advance(vad, vad.min_silence_ms, :speech_stopped, false)
    else
      {[], %{vad | run_ms: 0}}
    end
  end

  @doc "Feeds several frame probabilities in order."
  @spec process_all(t(), [number()]) :: {[event()], t()}
  def process_all(%__MODULE__{} = vad, probabilities) do
    {events, vad} =
      Enum.reduce(probabilities, {[], vad}, fn probability, {events, vad} ->
        {new_events, vad} = process(vad, probability)
        {Enum.reverse(new_events, events), vad}
      end)

    {Enum.reverse(events), vad}
  end

  defp advance(vad, required_ms, event, speaking?) do
    run_ms = vad.run_ms + vad.frame_ms

    if run_ms >= required_ms do
      {[event], %{vad | speaking?: speaking?, run_ms: 0}}
    else
      {[], %{vad | run_ms: run_ms}}
    end
  end
end
