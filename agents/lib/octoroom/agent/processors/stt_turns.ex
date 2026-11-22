defmodule Octoroom.Agent.Processors.STTTurns do
  @moduledoc """
  Turn taking by the STT provider's own endpointing.

  The user's turn ends with each non-empty final `Transcription` from the
  STT stage, which this stage replaces with one carrying a `turn_id`, after
  `UserStoppedSpeaking`. Barge-in happens once per stretch of speech, on
  whichever comes first: `VADUserStartedSpeaking` or an interim transcript
  (the VAD can miss speech that the STT provider hears). Without a VAD, a
  stretch lasts until the turn's final transcript.

  Options:

    * `:interrupt` (default `true`): `false` leaves out the `Interruption` and
      pushes only `UserStartedSpeaking`, for an agent's per-speaker front ends,
      where the agent decides who may interrupt.
    * `:vad` (default `true`): whether a VAD stage runs upstream.
    * `:finalize_on_vad` (default: the value of `:vad`): when `true`,
      `VADUserStoppedSpeaking` pushes `FinalizeTranscript` upstream if speech
      hasn't finalized yet, instead of waiting on the STT provider's silence
      timeout.
    * `:preemptive` (default: the value of `:finalize_on_vad`): when `true` and
      a non-empty interim transcript was seen, `VADUserStoppedSpeaking` also
      pushes `PreemptiveTranscription` downstream so the LLM can start while
      STT finalizes.
  """

  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Frames

  @impl true
  def init(opts, _ctx) do
    vad? = Keyword.get(opts, :vad, true)
    finalize_on_vad? = Keyword.get(opts, :finalize_on_vad, vad?)

    {:ok,
     %{
       interrupt?: Keyword.get(opts, :interrupt, true),
       finalize_on_vad?: finalize_on_vad?,
       preemptive?: Keyword.get(opts, :preemptive, finalize_on_vad?),
       barged_in?: false,
       pending?: false,
       last_interim: nil,
       turn_id: 0
     }}
  end

  @impl true
  def handle_frame(%Frames.VADUserStartedSpeaking{} = frame, :downstream, state),
    do:
      barge_in([{:push, frame, :downstream}], frame.source, %{
        state
        | pending?: true,
          last_interim: nil
      })

  # Each stretch of speech can barge in. Without this, a sound that never
  # becomes a transcript (a breath, a click) would leave `barged_in?` set,
  # and the next real interruption would be ignored until a transcript came.
  def handle_frame(%Frames.VADUserStoppedSpeaking{} = frame, :downstream, state) do
    finalize =
      if state.finalize_on_vad? and state.pending?,
        do: [{:push, %Frames.FinalizeTranscript{}, :upstream}],
        else: []

    preemptive =
      if state.preemptive? and state.pending? and is_binary(state.last_interim) and
           state.last_interim != "",
         do: [
           {:push, %Frames.PreemptiveTranscription{text: state.last_interim, source: frame.source},
            :downstream}
         ],
         else: []

    {[{:push, frame, :downstream} | finalize ++ preemptive],
     %{state | barged_in?: false, pending?: false, last_interim: nil}}
  end

  def handle_frame(%Frames.InterimTranscription{text: text} = frame, :downstream, state) do
    effects = [
      {:push, frame, :downstream},
      {:notify, {:transcription, %{status: "partial", text: text}}}
    ]

    # Also with a VAD: speech the VAD misses (it can, with the agent's voice
    # in the room) still barges in once the transcript shows it.
    barge_in(effects, frame.source, %{state | pending?: true, last_interim: text})
  end

  def handle_frame(%Frames.Transcription{turn_id: nil, text: ""}, :downstream, state),
    do: {[], %{state | barged_in?: false, pending?: false, last_interim: nil}}

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
     ], %{state | barged_in?: false, pending?: false, last_interim: nil, turn_id: turn_id}}
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
