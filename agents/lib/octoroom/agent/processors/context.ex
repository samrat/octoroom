defmodule Octoroom.Agent.Processors.Context do
  @moduledoc """
  The only owner of the conversation history.

  Inputs:

    * `Transcription` with a new `turn_id` - a user turn: the history gets it
      (after its `annotation`, if any, labelled `[speaker]` when it has one)
      and an `LLMContext` goes downstream, unless it has `respond: false`
    * `UserAudio` - a user turn heard as audio (half-cascaded); its
      conversation item is reserved until the transcript arrives
    * `Transcription` for an audio turn - replaces that turn's audio with
      text, so later requests don't resend it
    * `ToolResults` (upstream) - the next tool round, up to
      `max_tool_rounds`; after that the LLM answers without tools
    * `AssistantMessage` (upstream) - the reply, finished or interrupted.
      It comes once its audio has played, so it takes the place in the
      history that its turn reserved: turns heard while it played come
      after it. An interrupted reply holds only what was heard, and ends in
      `… [interrupted]` so the LLM knows it was cut off.
    * `AsyncToolResult` (upstream) - a non-blocking tool's result: noted
      silently, or a new turn about it
    * `Prompt` - a turn from the app (`Octoroom.Agent.prompt/3`), marked as
      not said by anyone on the call
    * `Start` - after `initial_delay_ms`, the agent's `initial_text` starts a
      turn

  It also emits the owner's conversation events (`Octoroom.Agent.ConversationEvents`),
  and sends the owner `{:voice_pipeline, pid, {:memory, memory}}` whenever
  what's worth keeping changes: `%{history: messages, conversation: %{id,
  sequence}}`, the history without replies still to come or turns still
  audio. The worker saves it, and a context started with `saved:` (in its
  runner context) carries on from it.

  Options (each defaults to the runner context's value): `:instructions`,
  `:initial_text`, `:tools`; plus `:max_tool_rounds` (4), `:max_history` (20),
  `:initial_delay_ms` (100).
  """

  use Octoroom.Agent.Processor

  # A reply's place in the history, until the reply comes back. Sent to the
  # LLM only once it has a draft (the reply is playing).
  @reply_pending %{role: "assistant", content: nil, reply_pending: true}

  require Logger

  alias Octoroom.Agent.Cascaded.AudioTurn
  alias Octoroom.Agent.ConversationEvents
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Restore
  alias Octoroom.Agent.ToolResult
  alias ReqLLM.Message.ContentPart

  @impl true
  def init(opts, ctx) do
    restore = Restore.normalize(Keyword.get(opts, :restore, Map.get(ctx, :restore, true)))
    saved = if restore.enabled?, do: Map.get(ctx, :saved) || %{}, else: %{}

    events =
      case saved do
        %{conversation: %{id: id, sequence: sequence}} ->
          %{ConversationEvents.new() | id: id, sequence: sequence}

        _ ->
          ConversationEvents.new()
      end

    saved_history = Map.get(saved, :history, [])
    history = Restore.restore_history(saved_history, restore)

    restore_prompt =
      if restore.enabled? and saved_history != [] do
        case restore.prompt do
          true -> true
          text when is_binary(text) and text != "" -> text
          _ -> nil
        end
      end

    state = %{
      instructions: Keyword.get(opts, :instructions, Map.get(ctx, :instructions)),
      initial_text: Keyword.get(opts, :initial_text, Map.get(ctx, :initial_text)),
      restore_prompt: restore_prompt,
      tools: Keyword.get(opts, :tools, Map.get(ctx, :tools, [])),
      max_tool_rounds: Keyword.get(opts, :max_tool_rounds, 4),
      max_history: Keyword.get(opts, :max_history, 20),
      initial_delay_ms: Keyword.get(opts, :initial_delay_ms, 100),
      frame_ttl_ms: Keyword.get(opts, :frame_ttl_ms, 10_000),
      max_frames: Keyword.get(opts, :max_frames, 4),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      # Latest video frame per source (`"<participant>/<source>"` => `%{frame, at}`).
      frames: %{},
      history: history,
      input: [],
      rounds_left: 0,
      audio_turns: %{},
      # The map `Octoroom.Agent.ConversationEvents` works on.
      events: %{owner: Map.get(ctx, :owner), conversation_events: events},
      # The last memory sent to the owner.
      memory: nil
    }

    {:ok, %{state | memory: memory(state)}}
  end

  @impl true
  def handle_frame(frame, direction, state), do: frame |> frame(direction, state) |> remember()

  @impl true
  def handle_timer(key, state), do: key |> timer(state) |> remember()

  # What a restarted agent needs to carry on, sent to the owner when it
  # changes.
  defp remember({effects, state}) do
    case memory(state) do
      same when same == state.memory ->
        {effects, state}

      memory ->
        owner = state.events.owner
        if is_pid(owner), do: send(owner, {:voice_pipeline, self(), {:memory, memory}})
        {effects, %{state | memory: memory}}
    end
  end

  defp memory(state) do
    %{
      history: Enum.reject(state.history, &(pending?(&1) or Map.has_key?(&1, :audio_turn_id))),
      conversation: Map.take(state.events.conversation_events, [:id, :sequence])
    }
  end

  defp frame(%Frames.InputImage{source: source} = image, :downstream, state) do
    {[], put_in(state.frames[source], %{frame: image, at: state.clock.()})}
  end

  defp frame(%Frames.VideoInactive{source: source}, :downstream, state) do
    {[], %{state | frames: Map.delete(state.frames, source)}}
  end

  defp frame(%Frames.Start{} = frame, :downstream, %{restore_prompt: prompt} = state)
       when not is_nil(prompt),
       do:
         {[{:push, frame, :downstream}, {:timer, :restore_prompt, state.initial_delay_ms}], state}

  defp frame(%Frames.Start{} = frame, :downstream, %{initial_text: text} = state)
       when is_binary(text) and text != "",
       do: {[{:push, frame, :downstream}, {:timer, :initial_text, state.initial_delay_ms}], state}

  defp frame(
         %Frames.Transcription{turn_id: turn_id, text: text} = frame,
         :downstream,
         state
       )
       when is_map_key(state.audio_turns, turn_id),
       do: audio_transcript(frame, text, state)

  defp frame(%Frames.Transcription{text: text} = frame, :downstream, state)
       when text != "" do
    extra = if frame.speaker, do: %{speaker: frame.speaker, source: frame.source}, else: %{}

    state =
      update_events(state, fn events ->
        events
        |> ConversationEvents.replace(:user, text)
        |> ConversationEvents.commit(:user, :completed, extra)
      end)

    message = %{role: "user", content: user_content(frame)}

    if frame.respond,
      do: start_turn(message, state, speaker_source: frame.source),
      else: {[], %{state | history: append(state.history, message, state)}}
  end

  defp frame(%Frames.UserAudio{} = frame, :downstream, state) do
    {events, reservation} = ConversationEvents.reserve(state.events)
    turn = %{reservation: reservation, speaker: frame.speaker, source: frame.source}

    state = %{
      state
      | events: events,
        audio_turns: Map.put(state.audio_turns, frame.turn_id, turn)
    }

    message = AudioTurn.message(frame.audio, frame.sample_rate, frame.turn_id, frame.speaker)

    if frame.respond,
      do: start_turn(message, state, speaker_source: frame.source),
      else: {[], %{state | history: append(state.history, message, state)}}
  end

  defp frame(%Frames.Prompt{text: text}, :downstream, state) when is_binary(text) do
    message = %{role: "user", content: "[From the app, not said by anyone on the call] " <> text}
    {effects, state} = start_turn(message, state)
    {[{:notify, {:status, "Thinking"}} | effects], state}
  end

  defp frame(%Frames.ToolResults{messages: messages, results: results}, :upstream, state) do
    input = state.input ++ messages
    state = record_tool_results(state, results)

    if state.rounds_left > 0 do
      state = %{state | input: input, rounds_left: state.rounds_left - 1}
      {[context_frame(input, state.tools)], state}
    else
      Logger.warning("tool round limit reached; answering without tools")
      {[context_frame(input, [])], %{state | input: input}}
    end
  end

  # The reply's text is done and its audio is playing: requests that start
  # meanwhile include it, and the app sees it now, marked `playing`, in its
  # place among the turns. Its `AssistantMessage` updates both.
  defp frame(%Frames.AssistantDraft{text: text}, :upstream, state) do
    case Enum.find_index(state.history, &(&1 == @reply_pending)) do
      nil ->
        {[], state}

      index ->
        {events, reservation} = ConversationEvents.reserve(state.events)

        events =
          ConversationEvents.update_reserved(events, :assistant, reservation, text, :playing)

        draft = state.history |> Enum.at(index) |> Map.merge(%{content: text, event: reservation})
        {[], %{state | events: events, history: List.replace_at(state.history, index, draft)}}
    end
  end

  defp frame(%Frames.AssistantMessage{} = message, :upstream, state) do
    status = if message.interrupted?, do: :interrupted, else: :completed
    text = message.text || ""

    state =
      case Enum.find(state.history, &pending?/1) do
        %{event: reservation} ->
          update_events(
            state,
            &ConversationEvents.update_reserved(&1, :assistant, reservation, text, status)
          )

        _no_draft ->
          update_events(state, fn events ->
            events
            |> ConversationEvents.replace(:assistant, text)
            |> ConversationEvents.commit(:assistant, status)
          end)
      end

    content = if message.interrupted?, do: interrupted(text), else: text
    history = fill_reply(state.history, %{role: "assistant", content: content}, state)

    notices =
      cond do
        message.interrupted? -> []
        text == "" -> [{:notify, {:status, "Listening"}}]
        true -> [{:notify, {:text, text}}, {:notify, {:status, "Listening"}}]
      end

    {notices, %{state | history: history}}
  end

  defp frame(
         %Frames.AsyncToolResult{result: %{scheduling: :silent} = result},
         :upstream,
         state
       ) do
    Logger.info("ASYNC_TOOL_RESULT name=#{result.name} scheduling=silent")
    emit_tool_result(state, ToolResult.summary(result))
    {[], %{state | history: append(state.history, async_result_message(result), state)}}
  end

  defp frame(%Frames.AsyncToolResult{result: result}, :upstream, state) do
    Logger.info("ASYNC_TOOL_RESULT name=#{result.name} scheduling=#{result.scheduling} speaking")
    emit_tool_result(state, ToolResult.summary(result))
    {effects, state} = start_turn(async_result_message(result), state)
    {[{:notify, {:status, "Thinking"}} | effects], state}
  end

  defp frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  defp timer(:initial_text, state) do
    {effects, state} = start_turn(%{role: "user", content: state.initial_text}, state)
    {[{:notify, {:status, "Thinking"}} | effects], state}
  end

  defp timer(:restore_prompt, %{restore_prompt: nil} = state), do: {[], state}

  defp timer(:restore_prompt, %{restore_prompt: true} = state) do
    state = %{state | restore_prompt: nil}

    {effects, state} =
      case List.last(state.history) do
        %{role: "user"} ->
          start_reply(state)

        _ ->
          start_turn(%{role: "user", content: Restore.default_context_notice()}, state)
      end

    {[{:notify, {:status, "Thinking"}} | effects], state}
  end

  defp timer(:restore_prompt, %{restore_prompt: text} = state) when is_binary(text) do
    message = %{role: "user", content: "[From the app, not said by anyone on the call] " <> text}
    {effects, state} = start_turn(message, %{state | restore_prompt: nil})
    {[{:notify, {:status, "Thinking"}} | effects], state}
  end

  defp audio_transcript(frame, text, state) do
    {turn, audio_turns} = Map.pop(state.audio_turns, frame.turn_id)
    extra = if turn.speaker, do: %{speaker: turn.speaker, source: turn.source}, else: %{}

    events =
      ConversationEvents.commit_reserved(state.events, :user, turn.reservation, text, extra)

    labelled = if turn.speaker, do: "[#{turn.speaker}] " <> text, else: text
    history = AudioTurn.replace_with_transcript(state.history, frame.turn_id, labelled)
    notice = {:notify, {:transcription, %{status: "final", text: text}}}
    {[notice], %{state | events: events, audio_turns: audio_turns, history: history}}
  end

  defp user_content(%Frames.Transcription{speaker: speaker} = frame) when is_binary(speaker),
    do: "[#{speaker}] " <> user_content(%{frame | speaker: nil})

  defp user_content(%Frames.Transcription{annotation: annotation, text: text})
       when is_binary(annotation) and annotation != "",
       do: annotation <> "\n" <> text

  defp user_content(%Frames.Transcription{text: text}), do: text

  # The reply's place in the history is reserved now, and filled when its
  # `AssistantMessage` comes back. Fresh video frames are attached only to
  # the outgoing turn's `LLMContext` and never stored in `history`.
  defp start_turn(message, state, opts \\ []) do
    cancel = if state.restore_prompt != nil, do: [{:cancel_timer, :restore_prompt}], else: []
    history = append(state.history, message, state)
    {effects, state} = start_reply(%{state | history: history, restore_prompt: nil}, opts)
    {cancel ++ effects, state}
  end

  defp start_reply(state, opts \\ []) do
    input =
      state.instructions
      |> prompt_input(state.history)
      |> attach_frames(state, Keyword.get(opts, :speaker_source))

    history = append(state.history, @reply_pending, state)
    state = %{state | history: history, input: input, rounds_left: state.max_tool_rounds}
    {[context_frame(input, state.tools)], state}
  end

  defp attach_frames(input, %{frames: frames}, _speaker_source) when map_size(frames) == 0,
    do: input

  defp attach_frames(input, state, speaker_source) do
    selected = select_frames(state, speaker_source)

    if selected == [] do
      input
    else
      image_parts =
        Enum.flat_map(selected, fn frame ->
          [
            ContentPart.text(frame_label(frame)),
            ContentPart.image(frame.image, frame.mime_type || "image/jpeg")
          ]
        end)

      List.update_at(input, -1, fn
        %{role: "user", content: text} = msg when is_binary(text) ->
          %{msg | content: image_parts ++ [ContentPart.text(text)]}

        %{role: "user", content: parts} = msg when is_list(parts) ->
          %{msg | content: image_parts ++ parts}

        other ->
          other
      end)
    end
  end

  # Fresh frames ordered by: screen shares first, then the current speaker's
  # camera, then other cameras (newest first within each tier).
  defp select_frames(state, speaker_source) do
    now = state.clock.()
    speaker_id = participant_id(speaker_source)

    state.frames
    |> Map.values()
    |> Enum.filter(&(now - &1.at <= state.frame_ttl_ms))
    |> Enum.sort_by(fn %{frame: f, at: at} ->
      tier =
        cond do
          frame_track_source(f) == "screen" -> 0
          speaker_id != nil and participant_id(f.source) == speaker_id -> 1
          true -> 2
        end

      {tier, -at}
    end)
    |> Enum.take(state.max_frames)
    |> Enum.map(& &1.frame)
  end

  defp frame_label(frame) do
    kind = frame_track_source(frame) || "video"

    case frame.speaker do
      name when is_binary(name) and name != "" -> "[#{name}'s #{kind}]"
      _ -> "[#{kind}]"
    end
  end

  defp frame_track_source(%{track_source: src}) when is_binary(src) and src != "", do: src

  defp frame_track_source(%{source: source}) when is_binary(source) do
    case String.split(source, "/", parts: 2) do
      [_id, kind] -> kind
      _ -> nil
    end
  end

  defp frame_track_source(_), do: nil

  defp participant_id(source) when is_binary(source), do: source |> String.split("/") |> hd()
  defp participant_id(_), do: nil

  # Into the oldest reserved place (replies come back in order), or at the
  # end if there's none; an empty reply just frees its place.
  defp fill_reply(history, %{content: content} = message, state) do
    case Enum.find_index(history, &pending?/1) do
      nil when content == "" -> history
      nil -> append(history, message, state)
      index when content == "" -> List.delete_at(history, index)
      index -> List.replace_at(history, index, message)
    end
  end

  defp pending?(message), do: Map.get(message, :reply_pending, false)

  defp interrupted(""), do: ""
  defp interrupted(text), do: text <> "… [interrupted]"

  defp context_frame(input, tools),
    do: {:push, %Frames.LLMContext{messages: input, tools: tools}, :downstream}

  defp prompt_input(instructions, history) when instructions in [nil, ""] do
    Enum.flat_map(history, fn
      %{reply_pending: true, content: nil} -> []
      %{reply_pending: true} = draft -> [Map.drop(draft, [:reply_pending, :event, :tool_result])]
      message -> [Map.drop(message, [:tool_result])]
    end)
  end

  defp prompt_input(instructions, history),
    do: [%{role: "system", content: instructions} | prompt_input(nil, history)]

  defp append(history, message, state), do: Enum.take(history ++ [message], -state.max_history)

  defp record_tool_results(state, []), do: state

  defp record_tool_results(state, results) when is_list(results) do
    Enum.each(results, &emit_tool_result(state, &1))

    message = tool_results_message(results)

    history =
      case Enum.find_index(state.history, &pending?/1) do
        nil -> append(state.history, message, state)
        index -> state.history |> List.insert_at(index, message) |> Enum.take(-state.max_history)
      end

    %{state | history: history}
  end

  defp record_tool_results(state, _other), do: state

  defp emit_tool_result(%{events: %{owner: owner}}, entry) when is_pid(owner) do
    send(owner, {:voice_pipeline, self(), {:tool_result, entry}})
  end

  defp emit_tool_result(_state, _entry), do: :ok

  defp tool_results_message([single]) do
    %{
      role: "user",
      content: "[Tool result, not said by the user] " <> ToolResult.format(single),
      tool_result: true
    }
  end

  defp tool_results_message(results) do
    lines = Enum.map_join(results, "\n", &ToolResult.format/1)

    %{
      role: "user",
      content: "[Tool results, not said by the user]\n" <> lines,
      tool_result: true
    }
  end

  defp update_events(state, fun), do: %{state | events: fun.(state.events)}

  defp async_result_message(%{name: name, response: response, scheduling: scheduling}) do
    instruction =
      if scheduling == :silent,
        do: "Keep this in mind and only mention it if it becomes relevant.",
        else: "Tell the user the result now, briefly."

    %{
      role: "user",
      content:
        "[Background result, not said by the user] The #{name} tool finished: " <>
          "#{encode(response)}. #{instruction}",
      tool_result: true
    }
  end

  defp encode(response) do
    case Jason.encode(response) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(response)
    end
  end
end
