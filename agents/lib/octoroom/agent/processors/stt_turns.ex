defmodule Octoroom.Agent.Processors.STTTurns do
  @moduledoc """
  Turn taking by the STT provider's own endpointing.

  The user's turn ends with each non-empty final `Transcription` from the
  STT stage, which this stage replaces with one carrying a `turn_id`, after
  `UserStoppedSpeaking`. Barge-in happens on `VADUserStartedSpeaking`, or,
  with `vad: false`, on the first interim transcript.

  Options: `:vad` (default `true`), and `:interrupt` (default `true`):
  `false` leaves out the `Interruption` and pushes only `UserStartedSpeaking`,
  for an agent's per-speaker front ends, where the agent decides who may
  interrupt.
  """

  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Frames

  @impl true
  def init(opts, _ctx),
    do:
      {:ok,
       %{
         vad?: Keyword.get(opts, :vad, true),
         interrupt?: Keyword.get(opts, :interrupt, true),
         barged_in?: false,
         turn_id: 0
       }}

  @impl true
  def handle_frame(%Frames.VADUserStartedSpeaking{} = frame, :downstream, state),
    do: barge_in([{:push, frame, :downstream}], frame.source, state)

  def handle_frame(%Frames.InterimTranscription{text: text} = frame, :downstream, state) do
    effects = [
      {:push, frame, :downstream},
      {:notify, {:transcription, %{status: "partial", text: text}}}
    ]

    if state.vad?, do: {effects, state}, else: barge_in(effects, frame.source, state)
  end

  def handle_frame(%Frames.Transcription{turn_id: nil, text: ""}, :downstream, state),
    do: {[], %{state | barged_in?: false}}

  def handle_frame(
        %Frames.Transcription{turn_id: nil, text: text, source: source} = frame,
        :downstream,
        state
      ) do
    turn_id = state.turn_id + 1

    {[
       {:notify, {:transcription, %{status: "final", text: text}}},
       {:notify, {:status, "Thinking"}},
       {:push, %Frames.UserStoppedSpeaking{turn_id: turn_id, source: source}, :downstream},
       # The same frame, numbered: what earlier stages put on it stays.
       {:push, %{frame | turn_id: turn_id}, :downstream}
     ], %{state | barged_in?: false, turn_id: turn_id}}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  defp barge_in(effects, _source, %{barged_in?: true} = state), do: {effects, state}

  defp barge_in(effects, source, state) do
    interruption =
      if state.interrupt?, do: [{:push, %Frames.Interruption{}, :downstream}], else: []

    {effects ++
       [{:push, %Frames.UserStartedSpeaking{source: source}, :downstream} | interruption],
     %{state | barged_in?: true}}
  end
end
