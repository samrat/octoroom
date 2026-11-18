defmodule Octoroom.Agent.Processors.AssistantCollector do
  @moduledoc """
  Collects the assistant's reply and sends it back to the context as an
  `AssistantMessage` once it's known how much of it people heard.

  Place it last, after TTS. Text from rounds that end in tool calls (a
  spoken preamble such as "let me check", or the tools stage's progress
  message) joins the final reply.

  ## What was said

  The LLM's text arrives long before its audio has played, so the reply's
  text alone doesn't say what people heard. The collector keeps a ledger of
  the reply as it passes: each `TTSText` chunk and how many ms of
  `OutputAudio` followed it. Then:

    * **The reply plays to the end.** The message goes upstream when its
      audio should have finished (`LLMResponseEnd` comes as soon as the
      audio is made, often seconds earlier), with the full text. Meanwhile
      an `AssistantDraft` with that text goes upstream at `LLMResponseEnd`,
      so a reply that starts while it plays knows what's being said.
    * **An interruption cuts it off.** The runner flushes the output and
      pushes `AudioFlushed` with how many ms never played. What was queued
      minus that is how far playback got; the ledger turns that into text:
      whole chunks that played, and the share of the words of the chunk that
      was playing, in proportion to how much of its audio played. That goes
      upstream marked `interrupted?: true`. If no `AudioFlushed` comes
      within `:flush_timeout_ms`, it assumes everything queued was heard.

  Before any audio, nothing was heard, so an interrupted reply's text is
  empty. With `voice: false` (no TTS) the text is what was said: an
  interrupted reply keeps what the LLM wrote before the interruption.

  Options: `:voice` (default true), `:flush_timeout_ms` (1000),
  `:playout_margin_ms` (100, added to the expected end of playback).
  """

  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Frames

  @impl true
  def init(opts, _ctx) do
    {:ok,
     %{
       voice: Keyword.get(opts, :voice, true),
       flush_timeout_ms: Keyword.get(opts, :flush_timeout_ms, 1_000),
       playout_margin_ms: Keyword.get(opts, :playout_margin_ms, 100),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       # The reply's text as the LLM wrote it.
       text: "",
       tool_round?: false,
       # Between the reply's first `LLMResponseStart` and its last
       # `LLMResponseEnd`.
       active?: false,
       # The ledger: `{text, ms}` per TTS chunk, newest first.
       chunks: [],
       audio_ms: 0.0,
       # When the reply's audio should finish playing (monotonic ms).
       play_end: nil,
       # A finished reply whose audio may still be playing: its full text.
       held: nil,
       # An interrupted reply waiting for `AudioFlushed`.
       cut: nil
     }}
  end

  @impl true
  # A round after tool calls continues the reply, separated by a space.
  def handle_frame(%Frames.LLMResponseStart{} = frame, :downstream, state) do
    # A new reply while the last one still plays, without an interruption:
    # the last one goes first.
    {effects, state} = release_held(state)
    text = if state.text == "", do: "", else: String.trim_trailing(state.text) <> " "

    {effects ++ [{:push, frame, :downstream}],
     %{state | text: text, active?: true, tool_round?: false}}
  end

  def handle_frame(%Frames.LLMText{text: text} = frame, :downstream, state) do
    # Progress speech arrives as " message" between rounds.
    text = if state.text == "", do: String.trim_leading(text), else: text
    {[{:push, frame, :downstream}], %{state | text: state.text <> text}}
  end

  def handle_frame(%Frames.TTSText{text: text} = frame, :downstream, state),
    do: {[{:push, frame, :downstream}], %{state | chunks: [{text, 0.0} | state.chunks]}}

  def handle_frame(
        %Frames.OutputAudio{audio: audio, sample_rate: rate} = frame,
        :downstream,
        state
      ) do
    ms = byte_size(audio) * 1_000 / (rate * 2)

    chunks =
      case state.chunks do
        [{text, chunk_ms} | rest] -> [{text, chunk_ms + ms} | rest]
        [] -> [{"", ms}]
      end

    # The output plays queued audio back to back, and starts again when
    # audio arrives after it ran dry.
    now = state.clock.()
    play_end = max(now, state.play_end || now) + ms

    {[{:push, frame, :downstream}],
     %{state | chunks: chunks, audio_ms: state.audio_ms + ms, play_end: play_end}}
  end

  def handle_frame(%Frames.ToolCalls{} = frame, :downstream, state),
    do: {[{:push, frame, :downstream}], %{state | tool_round?: true}}

  def handle_frame(%Frames.LLMResponseEnd{} = frame, :downstream, %{tool_round?: true} = state),
    do: {[{:push, frame, :downstream}], state}

  def handle_frame(%Frames.LLMResponseEnd{} = frame, :downstream, state) do
    text = String.trim(state.text)
    state = %{state | text: "", active?: false}

    if state.voice and state.audio_ms > 0 do
      wait = max(0, round(state.play_end - state.clock.())) + state.playout_margin_ms
      draft = {:push, %Frames.AssistantDraft{text: text}, :upstream}
      {[{:push, frame, :downstream}, draft, {:timer, :played, wait}], %{state | held: text}}
    else
      {[{:push, frame, :downstream}, message(text, false)], reset_ledger(state)}
    end
  end

  def handle_frame(%Frames.Interruption{}, _direction, state)
      when state.active? or state.held != nil do
    full = if state.held, do: state.held, else: String.trim(state.text)

    state = %{
      state
      | text: "",
        active?: false,
        tool_round?: false,
        held: nil
    }

    cond do
      not state.voice ->
        {[message(full, true)], reset_ledger(state)}

      state.audio_ms == 0 ->
        {[{:cancel_timer, :played}, message("", true)], reset_ledger(state)}

      true ->
        cut = %{full: full, chunks: Enum.reverse(state.chunks), audio_ms: state.audio_ms}

        {[{:cancel_timer, :played}, {:timer, :flush_timeout, state.flush_timeout_ms}],
         %{reset_ledger(state) | cut: cut}}
    end
  end

  def handle_frame(%Frames.Interruption{}, _direction, state), do: {[], state}

  def handle_frame(
        %Frames.AudioFlushed{dropped_ms: dropped} = frame,
        direction,
        %{cut: %{}} = state
      ) do
    played = state.cut.audio_ms - (dropped || 0)

    {[{:cancel_timer, :flush_timeout}, cut_message(state.cut, played), {:push, frame, direction}],
     %{state | cut: nil}}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_timer(:played, state), do: release_held(state)

  # No report of what played: assume everything queued was heard.
  def handle_timer(:flush_timeout, %{cut: %{} = cut} = state),
    do: {[cut_message(cut, cut.audio_ms)], %{state | cut: nil}}

  def handle_timer(_key, state), do: {[], state}

  @doc """
  The text of `chunks` (`{text, ms}`, oldest first) that `played_ms` of
  audio covers: whole chunks, then the share of the next chunk's words that
  its played audio covers, rounded down. Chunks with no audio weren't heard.
  """
  def spoken(chunks, played_ms) do
    {parts, _left} =
      Enum.reduce_while(chunks, {[], played_ms}, fn
        {_text, ms}, acc when ms <= 0 ->
          {:cont, acc}

        {text, ms}, {parts, left} when left >= ms ->
          {:cont, {[text | parts], left - ms}}

        {text, ms}, {parts, left} ->
          words = String.split(text)
          heard = Enum.take(words, floor(length(words) * max(left, 0) / ms))
          {:halt, {[Enum.join(heard, " ") | parts], 0}}
      end)

    parts
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp release_held(%{held: nil} = state), do: {[], state}

  defp release_held(state) do
    {[{:cancel_timer, :played}, message(state.held, false)], reset_ledger(%{state | held: nil})}
  end

  # A cut reply that played to the end wasn't cut short after all.
  defp cut_message(cut, played_ms) do
    if played_ms >= cut.audio_ms - 1,
      do: message(cut.full, false),
      else: message(spoken(cut.chunks, played_ms), true)
  end

  defp message(text, interrupted?),
    do: {:push, %Frames.AssistantMessage{text: text, interrupted?: interrupted?}, :upstream}

  defp reset_ledger(state), do: %{state | chunks: [], audio_ms: 0.0, play_end: nil}
end
