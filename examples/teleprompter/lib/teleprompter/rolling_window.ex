defmodule Teleprompter.RollingWindow do
  @moduledoc """
  Sits right before `Octoroom.Agent.Processors.Decisions` in the back end:

    1. Assigns a synthetic `turn_id` to typed turns (`turn_id: nil`) so typing a
       test utterance evaluates through Clef Flash identically to speech.
    2. Prepends the previous `window - 1` utterances as context in `frame.text`
       so a talking point spread across two or three sentences is still caught
       by the decision model, while stashing the exact current utterance in
       `frame.annotation` for display and quote capture.
  """
  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Frames

  @default_window 3

  @impl true
  def init(opts, _ctx) do
    {:ok, %{window: Keyword.get(opts, :window, @default_window), recent: [], seq: 0}}
  end

  @impl true
  def handle_frame(%Frames.Transcription{text: text} = frame, :downstream, state)
      when is_binary(text) do
    raw = String.trim(text)

    if raw == "" do
      {[{:push, frame, :downstream}], state}
    else
      {turn_id, seq} =
        case frame.turn_id do
          nil -> {{:typed, state.seq + 1}, state.seq + 1}
          id -> {id, state.seq}
        end

      recent = Enum.take(state.recent ++ [raw], -state.window)
      context_text = Enum.join(recent, "\n")

      enriched = %{frame | turn_id: turn_id, text: context_text, annotation: raw}
      {[{:push, enriched, :downstream}], %{state | recent: recent, seq: seq}}
    end
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_info({:teleprompter, :reset}, state), do: {[], %{state | recent: []}}
  def handle_info({:teleprompter, {:set_points, _}}, state), do: {[], %{state | recent: []}}
  def handle_info(_msg, state), do: {[], state}
end
