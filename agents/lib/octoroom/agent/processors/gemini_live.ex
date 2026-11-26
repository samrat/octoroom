defmodule Octoroom.Agent.Processors.GeminiLive do
  @moduledoc """
  Gemini Live speech-to-speech as one stage: `InputAudio` in (16 kHz),
  `OutputAudio` out (24 kHz). The model does its own turn-taking. When it
  reports that someone talked over it, this stage pushes an `Interruption`.
  When its reply is done generating, it pushes an `AssistantMessage`, though
  the audio may play for a while yet.

  Turns from the agent come in as text: a `Transcription` (typed by a
  participant, sent as `[speaker] text`), a `Prompt` (from the app), and
  `LLMText` (`Octoroom.Agent.say/3`, which asks the model to say it word for
  word: close, but it's the model's voice saying it, not text-to-speech).

  An `Interruption` from elsewhere (the agent's, for a typed turn or
  `interrupt/2`) drops the rest of the reply being generated; the model
  isn't told, so it thinks it was heard. Gemini doesn't know when its audio
  has played either, so this stage also notifies `:user_speaking` when it
  hears someone start a turn: the agent interrupts if its reply is still
  playing.

  Tool calls run in tasks of their own, which interruptions don't kill, and
  their results go back to the model. Their context's `speaker` is the
  participant who typed the last turn, or nil for speech (the model hears
  everyone mixed).

  Conversation items go to the owner (`Octoroom.Agent.ConversationEvents`):
  the model's transcripts of what it heard and what it said. User items
  have no `speaker` unless typed.

  Options: `:model` (needed, such as `"gemini-3.1-flash-live-preview"`),
  `:voice`, `:api_key` (default `GOOGLE_API_KEY`, then `GEMINI_API_KEY`),
  `:context_window_compression` (`false` to disable, or
  `[trigger_tokens: ..., target_tokens: ...]`; defaults to `104_857` / `52_428`),
  `:input_audio_transcription` (default `true`), `:output_audio_transcription`
  (default `true`), `:response_modalities` (default `["AUDIO"]`), and,
  defaulting to the runner context's, `:instructions`, `:initial_prompt`,
  `:initial_say`,
  `:tools` and `:context`. The socket starts only under a runner; for tests,
  pass `send: fn message -> ... end` to capture what would go to Gemini, and
  feed its events with `{:gemini_live_socket, event}` messages.
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.ConversationEvents
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.GeminiLive.{Protocol, WebSocket}
  alias Octoroom.Agent.Restore
  alias Octoroom.Agent.ToolAdapters.Gemini, as: GeminiTools
  alias Octoroom.Agent.ToolExecutor
  alias Octoroom.Agent.ToolResult

  @initial_prompt_delay_ms 1_000
  # How long without input audio before the model is told the stream paused
  # (everyone muted), so it doesn't wait for the rest of a sentence.
  @audio_end_ms 200

  @impl true
  def init(opts, ctx) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) -> start(model, opts, ctx)
      _none -> {:error, {:no_model, __MODULE__}}
    end
  end

  defp start(model, opts, ctx) do
    tools = Keyword.get(opts, :tools, Map.get(ctx, :tools, []))

    instructions = Keyword.get(opts, :instructions, Map.get(ctx, :instructions))
    restore = Restore.normalize(Keyword.get(opts, :restore, Map.get(ctx, :restore, true)))
    resume = if restore.enabled?, do: Map.get(ctx, :resume) || %{}, else: %{}
    handle = if restore.session, do: resume[:handle]

    if Keyword.has_key?(opts, :context_window_compression) do
      Protocol.context_window_compression(opts[:context_window_compression])
    end

    voice = Keyword.get(opts, :voice, Protocol.default_voice())

    setup =
      [
        model: model,
        voice: voice,
        system_instruction: instructions,
        tools: GeminiTools.to_declarations(tools)
      ] ++
        Keyword.take(opts, [
          :context_window_compression,
          :input_audio_transcription,
          :output_audio_transcription,
          :response_modalities
        ])

    # A new session after a restart: the model is told what was said and what tools returned.
    fallback_setup =
      Keyword.put(
        setup,
        :system_instruction,
        Restore.with_transcript(
          instructions,
          resume[:items],
          resume[:tool_results],
          restore,
          resume != %{}
        )
      )

    state = %{
      send: Keyword.get(opts, :send),
      model: model,
      voice: voice,
      telemetry: Map.get(ctx, :telemetry, %{}),
      connect_started_at: now(),
      user_turn: nil,
      response: nil,
      socket: nil,
      # Where tool tasks send their results: the runner, or a test.
      reply_to: Map.get(ctx, :runner) || self(),
      tools: tools,
      context: Keyword.get(opts, :context, Map.get(ctx, :context, %{})) || %{},
      initial_prompt: Keyword.get(opts, :initial_prompt, Map.get(ctx, :initial_prompt)),
      initial_say: Keyword.get(opts, :initial_say, Map.get(ctx, :initial_say)),
      started?: false,
      setup_complete?: false,
      sent_initial?: false,
      # The model is generating a reply, and whether to drop the rest of it
      # (interrupted here, not by the model).
      generating?: false,
      discard?: false,
      # Set while this stage's own `Interruption` goes round.
      interrupting?: false,
      # Someone's turn is being transcribed: `:user_speaking` went out.
      hearing?: false,
      model_text: "",
      last_audio_at: nil,
      audio_end_timer?: false,
      # Video sources seen recently: source => %{at, track_source, participant_id}.
      video_sources: %{},
      active_speaker_id: nil,
      last_video_sent_at: nil,
      min_video_interval_ms: Keyword.get(opts, :min_video_interval_ms, 900),
      video_ttl_ms: Keyword.get(opts, :video_ttl_ms, 5_000),
      clock: Keyword.get(opts, :clock, &now/0),
      owner: Map.get(ctx, :owner),
      conversation_events: ConversationEvents.new()
    }

    case ctx do
      %{runner: runner} when is_pid(runner) and is_nil(state.send) ->
        with {:ok, api_key} <- api_key(opts),
             {:ok, socket} <-
               WebSocket.start_link(
                 api_key: api_key,
                 parent: runner,
                 handle: handle,
                 setup: if(handle, do: setup, else: fallback_setup),
                 fallback_setup: fallback_setup
               ) do
          {:ok, %{state | socket: socket}}
        end

      _test ->
        # What it would connect with, for tests that pass `send:`.
        connect = [handle: handle, fallback_setup: fallback_setup]
        send_gemini(state, {:connect, connect})
        {:ok, state}
    end
  end

  defp api_key(opts) do
    key =
      Keyword.get(opts, :api_key) || System.get_env("GOOGLE_API_KEY") ||
        System.get_env("GEMINI_API_KEY")

    if is_binary(key) and key != "",
      do: {:ok, key},
      else: {:error, {:missing_env, "GOOGLE_API_KEY"}}
  end

  # -- Frames from the agent --

  @impl true
  def handle_frame(%Frames.InputAudio{audio: audio}, :downstream, state) do
    if state.setup_complete?, do: send_gemini(state, {:audio, audio})
    state = %{state | last_audio_at: now()}

    if state.audio_end_timer?,
      do: {[], state},
      else: {[{:timer, :audio_end, @audio_end_ms}], %{state | audio_end_timer?: true}}
  end

  def handle_frame(%Frames.InputImage{image: image, source: source} = frame, :downstream, state)
      when is_binary(image) do
    ts = state.clock.()

    entry = %{
      at: ts,
      track_source: frame.track_source || video_track_source(source),
      participant_id: video_participant_id(source)
    }

    video_sources =
      state.video_sources
      |> Map.put(source, entry)
      |> Map.filter(fn {_k, v} -> ts - v.at <= state.video_ttl_ms end)

    state = %{state | video_sources: video_sources}
    preferred = preferred_video_source(video_sources, state.active_speaker_id)

    can_send? =
      preferred == source and
        state.setup_complete? and
        (state.last_video_sent_at == nil or
           ts - state.last_video_sent_at >= state.min_video_interval_ms)

    if can_send? do
      send_gemini(state, {:video, image, mime_type: frame.mime_type || "image/jpeg"})
      {[], %{state | last_video_sent_at: ts}}
    else
      {[], state}
    end
  end

  def handle_frame(%Frames.VideoInactive{source: source}, :downstream, state) do
    {[], %{state | video_sources: Map.delete(state.video_sources, source)}}
  end

  def handle_frame(%Frames.Start{} = frame, :downstream, state) do
    state = %{state | started?: true}
    {[{:push, frame, :downstream} | initial_timer(state)], state}
  end

  def handle_frame(%Frames.Interruption{} = frame, :downstream, %{interrupting?: true} = state),
    do: {[{:push, frame, :downstream}], %{state | interrupting?: false}}

  def handle_frame(%Frames.Interruption{} = frame, :downstream, state) do
    state =
      if state.generating?,
        do: state |> emit_response_stop(:interrupted) |> commit_assistant(:interrupted),
        else: state

    {[{:push, frame, :downstream}], %{state | discard?: state.generating?}}
  end

  # A typed turn: who said it, for the model and for tools.
  def handle_frame(%Frames.Transcription{text: text} = frame, :downstream, state)
      when is_binary(text) do
    message = if frame.speaker, do: "[#{frame.speaker}] #{text}", else: text
    send_gemini(state, {:text, message})

    extra =
      Map.reject(%{speaker: frame.speaker, source: frame.source}, fn {_k, v} -> is_nil(v) end)

    ts = now()

    user_turn = %{
      started_at: ts,
      last_at: ts,
      text: text,
      speaker: frame.speaker,
      source: frame.source,
      typed?: true
    }

    state =
      state
      |> Map.put(:user_turn, user_turn)
      |> ConversationEvents.commit(:user, :completed)
      |> ConversationEvents.replace(:user, text)
      |> ConversationEvents.commit(:user, :completed, extra)

    {[], state}
  end

  def handle_frame(%Frames.Prompt{text: text}, :downstream, state) do
    send_gemini(state, {:text, "[From the app, not said by anyone on the call] " <> text})
    {[{:notify, {:status, "Thinking"}}], state}
  end

  def handle_frame(%Frames.LLMText{text: text}, :downstream, state) do
    send_gemini(
      state,
      {:text, "[From the app] Say this, word for word, and nothing else: " <> inspect(text)}
    )

    {[], state}
  end

  def handle_frame(%module{}, :downstream, state)
      when module in [Frames.LLMResponseStart, Frames.LLMResponseEnd],
      do: {[], state}

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_timer(:initial_say, %{sent_initial?: false} = state) do
    send_gemini(
      state,
      {:text,
       "[From the app] Say this, word for word, and nothing else: " <> inspect(state.initial_say)}
    )

    {[], %{state | sent_initial?: true}}
  end

  def handle_timer(:initial_prompt, %{sent_initial?: false} = state) do
    send_gemini(state, {:text, state.initial_prompt})
    {[], %{state | sent_initial?: true}}
  end

  def handle_timer(:audio_end, state) do
    case @audio_end_ms - (now() - state.last_audio_at) do
      left when left > 0 ->
        {[{:timer, :audio_end, left}], state}

      _quiet ->
        if state.setup_complete?, do: send_gemini(state, :audio_end)
        {[], %{state | audio_end_timer?: false}}
    end
  end

  def handle_timer(_key, state), do: {[], state}

  # -- From the model, and tool results --

  @impl true
  def handle_info({:gemini_live_socket, event}, state), do: event(event, state)

  def handle_info({:octoroom_agent_speaker, speaker}, state),
    do: {[], %{state | context: Map.put(state.context, :speaker, speaker)}}

  def handle_info({:octoroom_agent_active_speaker, participant_id}, state),
    do: {[], %{state | active_speaker_id: participant_id}}

  def handle_info({:octoroom_agent_frames, frames}, state),
    do: {[], %{state | context: Map.put(state.context, :frames, frames)}}

  def handle_info({:octoroom_agent_async_tool_result, %{response: response} = result}, state) do
    if is_pid(state.owner) do
      send(state.owner, {:voice_pipeline, self(), {:tool_result, ToolResult.summary(result)}})
    end

    response =
      %{id: result.call_id, name: result.name, response: response}
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    send_gemini(state, {:tool_response, [response]})
    events = if result.event, do: [{:notify, {:control, result.event}}], else: []
    {events, state}
  end

  def handle_info(_message, state), do: {[], state}

  @impl true
  def terminate(_reason, %{socket: socket}) when is_pid(socket), do: Process.exit(socket, :normal)
  def terminate(_reason, _state), do: :ok

  # Saved by the agent, to resume the session if it restarts.
  defp event({:resumption, handle}, state) do
    memory = %{gemini_handle: %{handle: handle, at: System.system_time(:millisecond)}}
    if is_pid(state.owner), do: send(state.owner, {:voice_pipeline, self(), {:memory, memory}})
    {[], state}
  end

  defp event(:resumption_failed, state) do
    Logger.warning(
      "Gemini Live couldn't resume the session; starting a new one with the transcript"
    )

    {[], state}
  end

  defp event(:connected, state), do: {[], %{state | setup_complete?: false}}

  defp event(:setup_complete, state) do
    dur = if state.connect_started_at, do: max(now() - state.connect_started_at, 0)
    emit_session(state, :started, if(dur, do: %{duration_ms: dur}, else: %{}))
    state = %{state | setup_complete?: true, connect_started_at: nil}
    {initial_timer(state), state}
  end

  defp event({:audio, _pcm, _rate}, %{discard?: true} = state), do: {[], state}

  defp event({:audio, pcm, sample_rate: rate}, state) do
    ts = now()

    state =
      state
      |> ensure_response_started(ts)
      |> record_response_audio(pcm, rate, ts)
      |> Map.merge(%{generating?: true, hearing?: false})

    frame = %Frames.OutputAudio{audio: pcm, sample_rate: rate}
    {[{:push, frame, :downstream}], state}
  end

  defp event({:text, _text}, %{discard?: true} = state), do: {[], state}

  defp event({:text, text}, state) do
    state = state |> ensure_response_started(now())
    {[], %{state | generating?: true, model_text: state.model_text <> text}}
  end

  # Someone started a turn: the agent stops if its reply is still playing.
  defp event({:transcription, :user, text, finished?}, state) do
    state = state |> ConversationEvents.append(:user, text) |> track_user_turn(text, now())

    {notify, state} =
      if String.trim(text) != "" and not state.hearing? and not state.generating?,
        do: {[{:notify, :user_speaking}], %{state | hearing?: true}},
        else: {[], state}

    state =
      if finished?,
        do: %{ConversationEvents.commit(state, :user) | hearing?: false},
        else: state

    {notify, state}
  end

  defp event({:transcription, :assistant, _text, _finished?}, %{discard?: true} = state),
    do: {[], state}

  defp event({:transcription, :assistant, text, _finished?}, state) do
    # The user's turn is over once the model answers.
    state = %{ConversationEvents.commit(state, :user) | hearing?: false}
    {[], ConversationEvents.append(state, :assistant, text)}
  end

  defp event({:tool_call, calls}, state) do
    ToolExecutor.run_async(calls, state.tools, state.context, reply_to: state.reply_to)
    {[], %{state | generating?: true}}
  end

  # The model heard someone talk over it and stopped generating.
  defp event(:interrupted, %{discard?: true} = state),
    do: {[], %{state | discard?: false, generating?: false, response: nil}}

  defp event(:interrupted, state) do
    state = state |> emit_response_stop(:interrupted) |> commit_assistant(:interrupted)

    {[{:push, %Frames.Interruption{}, :downstream}],
     %{state | generating?: false, interrupting?: true}}
  end

  defp event(:turn_complete, %{discard?: true} = state),
    do: {[], %{state | discard?: false, generating?: false, response: nil}}

  defp event(:turn_complete, state) do
    text = assistant_text(state)
    state = state |> emit_response_stop(:ok) |> commit_assistant(:completed)
    state = %{state | generating?: false}
    state = ConversationEvents.commit(state, :user)

    if text == "",
      do: {[], state},
      else: {[{:push, %Frames.AssistantMessage{text: text}, :downstream}], state}
  end

  defp event({:decode_error, reason}, state) do
    Logger.warning("Gemini Live decode error: #{inspect(reason)}")
    {[], state}
  end

  defp event({:disconnected, reason}, state) do
    Logger.warning("Gemini Live disconnected: #{inspect(reason)}; reconnecting")
    emit_session(state, :disconnected, %{}, %{reason: reason})
    state = ConversationEvents.commit(state, :user, :failed)

    state =
      if state.generating?,
        do: state |> emit_response_stop(:error, reason) |> commit_assistant(:failed),
        else: state

    {[{:notify, {:status, "Reconnecting"}}],
     %{
       state
       | setup_complete?: false,
         connect_started_at: now(),
         generating?: false,
         discard?: false,
         hearing?: false
     }}
  end

  defp event({:go_away, time_left}, state) do
    Logger.debug("Gemini Live closes this connection in #{inspect(time_left)}; will resume")
    {[], state}
  end

  defp event(_event, state), do: {[], state}

  # The transcript of the model's audio, or its text if it sent text instead.
  defp assistant_text(state) do
    case get_in(state, [:conversation_events, :pending, :assistant]) do
      text when is_binary(text) and text != "" -> text
      _ -> state.model_text
    end
  end

  defp commit_assistant(state, status) do
    text = assistant_text(state)

    state
    |> ConversationEvents.replace(:assistant, text)
    |> ConversationEvents.commit(:assistant, status)
    |> Map.put(:model_text, "")
  end

  defp initial_timer(%{sent_initial?: false, started?: true, setup_complete?: true} = s)
       when is_binary(s.initial_say) and s.initial_say != "",
       do: [{:timer, :initial_say, @initial_prompt_delay_ms}]

  defp initial_timer(%{sent_initial?: false, started?: true, setup_complete?: true} = s)
       when is_binary(s.initial_prompt) and s.initial_prompt != "",
       do: [{:timer, :initial_prompt, @initial_prompt_delay_ms}]

  defp initial_timer(_state), do: []

  defp now, do: System.monotonic_time(:millisecond)

  # -- Telemetry --

  defp track_user_turn(state, text, ts) do
    if String.trim(text || "") == "" do
      state
    else
      user_turn =
        case state.user_turn do
          %{typed?: false} = ut ->
            %{ut | last_at: ts, text: ut.text <> text}

          _ ->
            %{started_at: ts, last_at: ts, text: text, speaker: nil, source: nil, typed?: false}
        end

      %{state | user_turn: user_turn}
    end
  end

  defp ensure_response_started(%{response: %{} = _} = state, _ts), do: state

  defp ensure_response_started(state, ts) do
    user = state.user_turn

    response = %{
      started_at: ts,
      first_audio_at: nil,
      audio_ms: 0,
      audio_chunks: 0,
      user_last_at: user && user.last_at,
      user_text: user && String.trim(user.text || ""),
      speaker: user && user.speaker,
      source: user && user.source,
      typed?: (user && user.typed?) || false
    }

    :telemetry.execute(
      [:octoroom_agent, :live, :response, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      live_meta(state, %{speaker: response.speaker, typed: response.typed?})
    )

    %{state | response: response, user_turn: nil}
  end

  defp record_response_audio(state, <<>>, _rate, _ts), do: state

  defp record_response_audio(%{response: r} = state, pcm, rate, ts) do
    first_audio_at =
      if r.first_audio_at == nil do
        latency_ms = if r.user_last_at, do: max(ts - r.user_last_at, 0)

        measurements =
          %{system_time: System.system_time(), monotonic_time: System.monotonic_time()}
          |> then(fn m ->
            if latency_ms, do: Map.put(m, :response_latency_ms, latency_ms), else: m
          end)

        :telemetry.execute(
          [:octoroom_agent, :live, :response, :first_audio],
          measurements,
          live_meta(state, %{speaker: r.speaker, typed: r.typed?})
        )

        ts
      else
        r.first_audio_at
      end

    chunk_ms =
      if is_integer(rate) and rate > 0, do: div(byte_size(pcm) * 1_000, rate * 2), else: 0

    %{
      state
      | response: %{
          r
          | first_audio_at: first_audio_at,
            audio_ms: r.audio_ms + chunk_ms,
            audio_chunks: r.audio_chunks + 1
        }
    }
  end

  defp emit_response_stop(state, status, reason \\ nil)
  defp emit_response_stop(%{response: nil} = state, _status, _reason), do: state

  defp emit_response_stop(%{response: r} = state, status, reason) do
    ended_at = now()
    duration_ms = max(ended_at - r.started_at, 0)
    duration = System.convert_time_unit(duration_ms, :millisecond, :native)

    latency_ms =
      if r.user_last_at && r.first_audio_at, do: max(r.first_audio_at - r.user_last_at, 0)

    measurements =
      %{
        duration: duration,
        duration_ms: duration_ms,
        audio_ms: r.audio_ms,
        outputs: r.audio_chunks,
        ended_at_ms: ended_at
      }
      |> then(fn m ->
        if latency_ms, do: Map.put(m, :response_latency_ms, latency_ms), else: m
      end)

    extra =
      %{
        status: status,
        speaker: r.speaker,
        input: r.source,
        typed: r.typed?,
        user_text: if(r.user_text not in [nil, ""], do: r.user_text),
        assistant_text: assistant_text(state)
      }
      |> then(fn m -> if reason, do: Map.put(m, :reason, reason), else: m end)

    :telemetry.execute(
      [:octoroom_agent, :live, :response, :stop],
      measurements,
      live_meta(state, extra)
    )

    %{state | response: nil}
  end

  defp emit_session(state, event, measurements, extra \\ %{}) do
    :telemetry.execute(
      [:octoroom_agent, :live, :session],
      Map.merge(
        %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
        measurements
      ),
      live_meta(state, Map.put(extra, :event, event))
    )
  end

  defp live_meta(state, extra) do
    state.telemetry
    |> Map.merge(%{
      provider: :gemini,
      model: state.model,
      voice: state.voice,
      transport: :websocket
    })
    |> Map.merge(extra)
  end

  defp send_gemini(%{send: send}, message) when is_function(send, 1), do: send.(message)
  defp send_gemini(%{socket: nil}, _message), do: :ok

  defp send_gemini(%{socket: socket}, {:audio, audio}),
    do: WebSocket.send_audio(socket, audio, sample_rate: Protocol.send_sample_rate())

  defp send_gemini(%{socket: socket}, {:video, data, opts}),
    do: WebSocket.send_video(socket, data, opts)

  defp send_gemini(%{socket: socket}, :audio_end), do: WebSocket.send_audio_end(socket)
  defp send_gemini(%{socket: socket}, {:text, text}), do: WebSocket.send_text(socket, text)

  defp send_gemini(%{socket: socket}, {:tool_response, responses}),
    do: WebSocket.send_tool_response(socket, responses)

  # Picks one active video source so Gemini Live's single video stream never
  # flickers between participants: active screen share first, then the active
  # speaker's camera, then the most recently seen source.
  defp preferred_video_source(sources, _active_speaker_id) when map_size(sources) == 0, do: nil

  defp preferred_video_source(sources, active_speaker_id) do
    {source, _entry} =
      Enum.min_by(sources, fn {_src, entry} ->
        tier =
          cond do
            entry.track_source == "screen" -> 0
            active_speaker_id != nil and entry.participant_id == active_speaker_id -> 1
            true -> 2
          end

        {tier, -entry.at}
      end)

    source
  end

  defp video_track_source(source) when is_binary(source) do
    case String.split(source, "/", parts: 2) do
      [_id, kind] -> kind
      _ -> nil
    end
  end

  defp video_track_source(_), do: nil

  defp video_participant_id(source) when is_binary(source),
    do: source |> String.split("/") |> hd()

  defp video_participant_id(_), do: nil
end
