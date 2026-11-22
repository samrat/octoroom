defmodule Octoroom.Agent.Processors.OpenAILive do
  @moduledoc """
  OpenAI Live (`gpt-live-1.1` / `gpt-live-1`) full-duplex speech-to-speech as
  one stage: `InputAudio` in (resampled from 16 kHz to 24 kHz by default),
  `OutputAudio` out (24 kHz). The model listens and speaks simultaneously and
  takes its own turns.

  Turns from the agent come in as text sent through `session.commentary.append`:
  a `Transcription` (typed by a participant, sent as `[speaker] text`), a
  `Prompt` (from the app), and `LLMText` (`Octoroom.Agent.say/3`, which asks
  the model to say the words verbatim).

  Because OpenAI Live is full-duplex and streams append-only audio and
  transcript deltas without per-turn completion markers, this stage commits
  user and assistant turns after brief idle pauses (`:user_idle` and
  `:assistant_idle`), pushing an `AssistantMessage` when an utterance settles
  so presence returns to `"listening"`. When it hears someone start speaking
  while an earlier reply's audio may still be playing, it notifies
  `:user_speaking` so the agent interrupts playback.

  Tools run through OpenAI Live's Responses delegation (`delegation: [model: ...]`).
  Any `%Octoroom.Agent.Tool{}` structs from the agent are declared alongside
  hosted tools in `delegation.responses.tools`; incoming `function_call` items
  run asynchronously via `Octoroom.Agent.ToolExecutor`, returning
  `response.item.create` (`function_call_output`) and a single `response.create`
  once a batch finishes. With `delegation: :client`, `session.delegation.created`
  events are notified as `{:delegation, delegation}`.

  Conversation items go to the owner (`Octoroom.Agent.ConversationEvents`):
  the model's input and output transcripts. User items have no `speaker`
  unless typed.

  Options: `:model` (needed, such as `"gpt-live-1.1"`), `:voice` (default
  `"marin"`), `:api_key` (default `OPENAI_API_KEY`), `:transport` (`:webrtc`,
  the default, or `:websocket`), `:sample_rate` (`24_000` default, or `16_000`;
  WebSocket only), `:delegation` (`:client`, `[model: "...", ...]`, or a
  delegation map), `:idle_timeout_s` (`5..60` seconds before standby, or `nil`
  to omit; WebRTC only), `:wake_policy` (`:speech`, `[type: :speech,
  vad_threshold: 0.5]`, or a map; WebRTC only), `:initial_items`, and,
  defaulting to the runner context's, `:instructions`, `:initial_text`,
  `:tools` and `:context`. The transport starts only under a runner; for tests,
  pass `send: fn message -> ... end` to capture what would go to OpenAI, and
  feed its events with `{:openai_live_socket, event}`.
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Audio.PCM16
  alias Octoroom.Agent.ConversationEvents
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.OpenAILive.{Protocol, WebRTC, WebSocket}
  alias Octoroom.Agent.ToolExecutor

  @output_sample_rate 24_000
  @initial_text_delay_ms 1_000
  # Quiet gap with no input audio before telling OpenAI Live to feed silence.
  @audio_end_ms 200
  # Idle gaps used to finalize full-duplex transcript/audio bursts.
  @assistant_idle_ms 600
  @user_idle_ms 800

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
    resume = Map.get(ctx, :resume) || %{}
    transport = Protocol.transport(Keyword.get(opts, :transport, Protocol.default_transport()))

    sample_rate =
      Protocol.sample_rate(Keyword.get(opts, :sample_rate, Protocol.default_sample_rate()))

    delegation = Keyword.get(opts, :delegation)

    if delegation != nil do
      Protocol.delegation(delegation, tools)
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

    if tools != [] and delegation in [nil, false] do
      Logger.warning(
        "OpenAI Live has #{length(tools)} tool(s) but no :delegation configured; " <>
          "pass delegation: [model: \"...\"] to enable tool calls"
      )
    end

    voice = Keyword.get(opts, :voice, Protocol.default_voice())

    setup =
      [
        model: model,
        voice: voice,
        sample_rate: sample_rate,
        instructions: with_transcript(instructions, resume[:items]),
        delegation: delegation,
        tools: tools
      ] ++ Keyword.take(opts, [:initial_items, :idle_timeout_s, :wake_policy])

    state = %{
      send: Keyword.get(opts, :send),
      transport: transport,
      model: model,
      voice: voice,
      telemetry: Map.get(ctx, :telemetry, %{}),
      connect_started_at: now(),
      user_turn: nil,
      response: nil,
      socket: nil,
      reply_to: Map.get(ctx, :runner) || self(),
      tools: tools,
      context: Keyword.get(opts, :context, Map.get(ctx, :context, %{})) || %{},
      initial_text: Keyword.get(opts, :initial_text, Map.get(ctx, :initial_text)),
      sample_rate: sample_rate,
      in_resample: nil,
      out_resample: nil,
      started?: false,
      session_started?: false,
      sent_initial_text?: false,
      input_muted?: false,
      generating?: false,
      discard?: false,
      hearing?: false,
      last_audio_at: nil,
      audio_end_timer?: false,
      last_output_at: nil,
      assistant_idle_timer?: false,
      last_user_transcript_at: nil,
      user_idle_timer?: false,
      pending_tool_calls: MapSet.new(),
      owner: Map.get(ctx, :owner),
      conversation_events: ConversationEvents.new()
    }

    case ctx do
      %{runner: runner} when is_pid(runner) and is_nil(state.send) ->
        transport_mod = transport_module(transport)

        with {:ok, api_key} <- api_key(opts),
             {:ok, socket} <-
               transport_mod.start_link(
                 api_key: api_key,
                 parent: runner,
                 setup: setup
               ) do
          {:ok, %{state | socket: socket}}
        end

      _test ->
        send_openai(state, {:connect, [transport: transport, setup: setup]})
        {:ok, state}
    end
  end

  defp transport_module(:webrtc), do: WebRTC
  defp transport_module(:websocket), do: WebSocket

  defp api_key(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    if is_binary(key) and key != "",
      do: {:ok, key},
      else: {:error, {:missing_env, "OPENAI_API_KEY"}}
  end

  # -- Frames from the agent --

  @impl true
  def handle_frame(
        %Frames.InputAudio{audio: audio, sample_rate: rate},
        :downstream,
        %{transport: :webrtc} = state
      ) do
    # WebRTC paces Opus RTP (with silence when idle) directly; audio can flow
    # as soon as the peer is up, including to wake a speech-policy session.
    if state.session_started? or state.socket != nil do
      send_openai(state, {:audio, audio, sample_rate: rate})
    end

    {[], %{state | last_audio_at: now()}}
  end

  def handle_frame(%Frames.InputAudio{audio: audio, sample_rate: rate}, :downstream, state) do
    state =
      if state.session_started? do
        state =
          if state.input_muted? do
            send_openai(state, :unmute)
            %{state | input_muted?: false}
          else
            state
          end

        {pcm, resample} = PCM16.resample_stream(audio, rate, state.sample_rate, state.in_resample)
        if pcm != <<>>, do: send_openai(state, {:audio, pcm})
        %{state | in_resample: resample}
      else
        state
      end

    state = %{state | last_audio_at: now()}

    if state.audio_end_timer?,
      do: {[], state},
      else: {[{:timer, :audio_end, @audio_end_ms}], %{state | audio_end_timer?: true}}
  end

  def handle_frame(%Frames.Start{} = frame, :downstream, state) do
    state = %{state | started?: true}
    {[{:push, frame, :downstream} | initial_text_timer(state)], state}
  end

  def handle_frame(%Frames.Interruption{} = frame, :downstream, state) do
    state =
      if state.generating? do
        state |> emit_response_stop(:interrupted) |> commit_assistant(:interrupted)
      else
        state
      end

    {timers, state} =
      if state.generating? do
        state = %{state | generating?: false, discard?: true, last_output_at: now()}
        ensure_assistant_idle_timer(state)
      else
        {[], state}
      end

    {[{:push, frame, :downstream} | timers], state}
  end

  # A typed turn: who said it, for the model and for tools.
  def handle_frame(%Frames.Transcription{text: text} = frame, :downstream, state)
      when is_binary(text) do
    message = if frame.speaker, do: "[#{frame.speaker}] #{text}", else: text
    send_openai(state, {:commentary, message})

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
      |> Map.merge(%{discard?: false, user_turn: user_turn})
      |> ConversationEvents.commit(:user, :completed)
      |> ConversationEvents.replace(:user, text)
      |> ConversationEvents.commit(:user, :completed, extra)

    {[], state}
  end

  def handle_frame(%Frames.Prompt{text: text}, :downstream, state) do
    send_openai(state, {:commentary, "[From the app, not said by anyone on the call] " <> text})
    {[{:notify, {:status, "Thinking"}}], %{state | discard?: false}}
  end

  def handle_frame(%Frames.LLMText{text: text}, :downstream, state) do
    send_openai(
      state,
      {:commentary, "[From the app] Say this, word for word, and nothing else: " <> inspect(text)}
    )

    {[], %{state | discard?: false}}
  end

  def handle_frame(%module{}, :downstream, state)
      when module in [
             Frames.LLMResponseStart,
             Frames.LLMResponseEnd,
             Frames.InputImage,
             Frames.VideoInactive
           ],
      do: {[], state}

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  # -- Timers --

  @impl true
  def handle_timer(:initial_text, %{sent_initial_text?: false} = state) do
    send_openai(state, {:commentary, state.initial_text})
    {[], %{state | sent_initial_text?: true}}
  end

  def handle_timer(:audio_end, state) do
    case @audio_end_ms - (now() - state.last_audio_at) do
      left when left > 0 ->
        {[{:timer, :audio_end, left}], state}

      _quiet ->
        state =
          if state.session_started? and not state.input_muted? do
            send_openai(state, :mute)
            %{state | input_muted?: true}
          else
            state
          end

        {[], %{state | audio_end_timer?: false}}
    end
  end

  def handle_timer(:assistant_idle, %{last_output_at: nil} = state),
    do: {[], %{state | assistant_idle_timer?: false}}

  def handle_timer(:assistant_idle, state) do
    case @assistant_idle_ms - (now() - state.last_output_at) do
      left when left > 0 ->
        {[{:timer, :assistant_idle, left}], state}

      _idle ->
        finish_assistant_turn(%{state | assistant_idle_timer?: false})
    end
  end

  def handle_timer(:user_idle, %{last_user_transcript_at: nil} = state),
    do: {[], %{state | user_idle_timer?: false}}

  def handle_timer(:user_idle, state) do
    case @user_idle_ms - (now() - state.last_user_transcript_at) do
      left when left > 0 ->
        {[{:timer, :user_idle, left}], state}

      _idle ->
        state =
          state
          |> ConversationEvents.commit(:user, :completed)
          |> Map.merge(%{hearing?: false, user_idle_timer?: false})

        {[], state}
    end
  end

  def handle_timer(_key, state), do: {[], state}

  # -- From the model, and tool results --

  @impl true
  def handle_info({:openai_live_socket, event}, state), do: event(event, state)

  def handle_info({:octoroom_agent_speaker, speaker}, state),
    do: {[], %{state | context: Map.put(state.context, :speaker, speaker)}}

  def handle_info({:octoroom_agent_frames, frames}, state),
    do: {[], %{state | context: Map.put(state.context, :frames, frames)}}

  def handle_info({:octoroom_agent_async_tool_result, %{response: response} = result}, state) do
    send_openai(state, {:tool_output, result.call_id, response})
    pending = MapSet.delete(state.pending_tool_calls, result.call_id)
    if MapSet.size(pending) == 0, do: send_openai(state, :response_create)
    events = if result.event, do: [{:notify, {:control, result.event}}], else: []
    {events, %{state | pending_tool_calls: pending}}
  end

  def handle_info({:openai_live, kind, content, opts}, state)
      when kind in [:commentary, :thinking, :instructions] and is_binary(content) and
             is_list(opts) do
    send_openai(state, {kind, content, opts})
    {[], state}
  end

  def handle_info(_message, state), do: {[], state}

  @impl true
  def terminate(_reason, %{socket: socket, transport: transport}) when is_pid(socket) do
    transport_module(transport).close(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Socket events --

  defp event(:connected, state),
    do: {[], %{state | session_started?: false, input_muted?: false}}

  defp event({:session_started, _session}, state) do
    dur = if state.connect_started_at, do: max(now() - state.connect_started_at, 0)
    emit_session(state, :started, if(dur, do: %{duration_ms: dur}, else: %{}))
    state = %{state | session_started?: true, connect_started_at: nil}
    {initial_text_timer(state), state}
  end

  defp event({:audio, _pcm, _rate}, %{discard?: true} = state) do
    state = %{state | last_output_at: now()}
    ensure_assistant_idle_timer(state)
  end

  defp event({:audio, pcm, sample_rate: rate}, state) do
    {out_pcm, resample} =
      PCM16.resample_stream(pcm, rate, @output_sample_rate, state.out_resample)

    ts = now()

    state =
      state
      |> ConversationEvents.commit(:user, :completed)
      |> ensure_response_started(ts)
      |> record_response_audio(out_pcm, ts)
      |> Map.merge(%{
        generating?: true,
        hearing?: false,
        out_resample: resample,
        last_output_at: ts
      })

    {timers, state} = ensure_assistant_idle_timer(state)

    if out_pcm == <<>> do
      {timers, state}
    else
      frame = %Frames.OutputAudio{audio: out_pcm, sample_rate: @output_sample_rate}
      {[{:push, frame, :downstream} | timers], state}
    end
  end

  defp event({:transcription, :user, text}, state) do
    ts = now()
    state = state |> ConversationEvents.append(:user, text) |> track_user_turn(text, ts)

    {notify, state} =
      if String.trim(text) != "" and not state.hearing? and not state.generating?,
        do: {[{:notify, :user_speaking}], %{state | hearing?: true}},
        else: {[], state}

    {timers, state} = ensure_user_idle_timer(%{state | last_user_transcript_at: ts})
    {notify ++ timers, state}
  end

  defp event({:transcription, :assistant, _text}, %{discard?: true} = state) do
    state = %{state | last_output_at: now()}
    ensure_assistant_idle_timer(state)
  end

  defp event({:transcription, :assistant, text}, state) do
    ts = now()

    state =
      state
      |> ConversationEvents.commit(:user, :completed)
      |> ConversationEvents.append(:assistant, text)
      |> ensure_response_started(ts)
      |> Map.merge(%{generating?: true, hearing?: false, last_output_at: ts})

    ensure_assistant_idle_timer(state)
  end

  defp event({:tool_call, calls}, state) do
    ids = for call <- calls, is_binary(call[:id]), do: call.id
    pending = Enum.reduce(ids, state.pending_tool_calls, &MapSet.put(&2, &1))
    ToolExecutor.run_async(calls, state.tools, state.context, reply_to: state.reply_to)
    {[], %{state | generating?: true, pending_tool_calls: pending}}
  end

  defp event({:delegation_created, delegation}, state),
    do: {[{:notify, {:delegation, delegation}}], state}

  defp event({:session_paused, _frame}, state) do
    Logger.debug("OpenAI Live session paused (standby)")
    emit_session(state, :paused)
    state = ConversationEvents.commit(state, :user, :completed)

    state =
      if state.generating?,
        do: state |> emit_response_stop(:ok) |> commit_assistant(:completed),
        else: state

    {[{:notify, :session_paused}], %{state | generating?: false, hearing?: false}}
  end

  defp event({:session_resumed, _frame}, state) do
    Logger.debug("OpenAI Live session resumed")
    emit_session(state, :resumed)
    {[{:notify, :session_resumed}], state}
  end

  defp event({:error, error}, state) do
    Logger.warning("OpenAI Live error: #{inspect(error)}")
    emit_session(state, :error, %{}, %{reason: error})
    frame = %Frames.Error{processor: __MODULE__, reason: error, fatal?: false}
    {[{:push, frame, :upstream}], state}
  end

  defp event({:session_closed, reason, _frame}, state) do
    Logger.info("OpenAI Live session closed: #{inspect(reason)}")
    emit_session(state, :closed, %{}, %{reason: reason})
    state = ConversationEvents.commit(state, :user, :completed)

    state =
      if state.generating?,
        do: state |> emit_response_stop(:ok) |> commit_assistant(:completed),
        else: state

    {[],
     %{
       state
       | session_started?: false,
         generating?: false,
         discard?: false,
         hearing?: false,
         input_muted?: false
     }}
  end

  defp event({:decode_error, reason}, state) do
    Logger.warning("OpenAI Live decode error: #{inspect(reason)}")
    {[], state}
  end

  defp event({:disconnected, reason}, state) do
    Logger.warning("OpenAI Live disconnected: #{inspect(reason)}; reconnecting")
    emit_session(state, :disconnected, %{}, %{reason: reason})
    state = ConversationEvents.commit(state, :user, :failed)

    state =
      if state.generating?,
        do: state |> emit_response_stop(:error, reason) |> commit_assistant(:failed),
        else: state

    {[{:notify, {:status, "Reconnecting"}}],
     %{
       state
       | session_started?: false,
         connect_started_at: now(),
         generating?: false,
         discard?: false,
         hearing?: false,
         input_muted?: false,
         in_resample: nil,
         out_resample: nil,
         pending_tool_calls: MapSet.new()
     }}
  end

  defp event(_event, state), do: {[], state}

  defp finish_assistant_turn(%{discard?: true} = state),
    do: {[], %{state | discard?: false, generating?: false, response: nil}}

  defp finish_assistant_turn(%{generating?: false} = state), do: {[], state}

  defp finish_assistant_turn(state) do
    text = assistant_text(state)
    state = state |> emit_response_stop(:ok) |> commit_assistant(:completed)
    state = %{state | generating?: false}
    {[{:push, %Frames.AssistantMessage{text: text}, :downstream}], state}
  end

  defp ensure_assistant_idle_timer(%{assistant_idle_timer?: true} = state), do: {[], state}

  defp ensure_assistant_idle_timer(state),
    do: {[{:timer, :assistant_idle, @assistant_idle_ms}], %{state | assistant_idle_timer?: true}}

  defp ensure_user_idle_timer(%{user_idle_timer?: true} = state), do: {[], state}

  defp ensure_user_idle_timer(state),
    do: {[{:timer, :user_idle, @user_idle_ms}], %{state | user_idle_timer?: true}}

  # The conversation so far (the agent's saved items), after the instructions,
  # when restarting mid-call.
  @transcript_items 50
  @transcript_chars 8_000

  defp with_transcript(instructions, [_ | _] = items) do
    lines =
      items
      |> Enum.take(-@transcript_items)
      |> Enum.map_join("\n", fn
        %{role: "assistant", text: text} -> "You: " <> text
        %{speaker: speaker, text: text} when is_binary(speaker) -> "[#{speaker}] " <> text
        %{text: text} -> "[someone] " <> text
      end)

    lines = String.slice(lines, -@transcript_chars, @transcript_chars)

    prefix =
      if is_binary(instructions) and instructions != "", do: instructions <> "\n\n", else: ""

    prefix <>
      "You were restarted in the middle of this call. " <>
      "What was said before, oldest first:\n" <> lines
  end

  defp with_transcript(instructions, _none), do: instructions

  defp assistant_text(state) do
    case get_in(state, [:conversation_events, :pending, :assistant]) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp commit_assistant(state, status) do
    ConversationEvents.commit(state, :assistant, status)
  end

  defp initial_text_timer(
         %{sent_initial_text?: false, started?: true, session_started?: true} = s
       )
       when is_binary(s.initial_text) and s.initial_text != "",
       do: [{:timer, :initial_text, @initial_text_delay_ms}]

  defp initial_text_timer(_state), do: []

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
      audio_bytes: 0,
      audio_chunks: 0,
      user_started_at: user && user.started_at,
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

  defp record_response_audio(state, <<>>, _ts), do: state

  defp record_response_audio(%{response: r} = state, pcm, ts) do
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

    %{
      state
      | response: %{
          r
          | first_audio_at: first_audio_at,
            audio_bytes: r.audio_bytes + byte_size(pcm),
            audio_chunks: r.audio_chunks + 1
        }
    }
  end

  defp emit_response_stop(state, status, reason \\ nil)
  defp emit_response_stop(%{response: nil} = state, _status, _reason), do: state

  defp emit_response_stop(%{response: r} = state, status, reason) do
    ended_at = state.last_output_at || now()
    duration_ms = max(ended_at - r.started_at, 0)
    duration = System.convert_time_unit(duration_ms, :millisecond, :native)

    latency_ms =
      if r.user_last_at && r.first_audio_at, do: max(r.first_audio_at - r.user_last_at, 0)

    # 24 kHz mono s16le = 48 bytes per ms
    audio_ms = div(r.audio_bytes, 48)

    measurements =
      %{
        duration: duration,
        duration_ms: duration_ms,
        audio_ms: audio_ms,
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

  defp emit_session(state, event, measurements \\ %{}, extra \\ %{}) do
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
      provider: :openai,
      model: state.model,
      voice: state.voice,
      transport: state.transport
    })
    |> Map.merge(extra)
  end

  defp send_openai(%{send: send}, message) when is_function(send, 1), do: send.(message)
  defp send_openai(%{socket: nil}, _message), do: :ok

  defp send_openai(%{socket: socket, transport: :webrtc}, {:audio, audio, opts}),
    do: WebRTC.send_audio(socket, audio, opts)

  defp send_openai(%{socket: socket, transport: transport}, {:audio, audio}),
    do: transport_module(transport).send_audio(socket, audio)

  defp send_openai(%{socket: socket, transport: transport}, :mute),
    do: transport_module(transport).send_mute(socket)

  defp send_openai(%{socket: socket, transport: transport}, :unmute),
    do: transport_module(transport).send_unmute(socket)

  defp send_openai(%{socket: socket, transport: transport}, {:commentary, text}),
    do: transport_module(transport).send_commentary(socket, text)

  defp send_openai(%{socket: socket, transport: transport}, {:commentary, text, opts}),
    do: transport_module(transport).send_commentary(socket, text, opts)

  defp send_openai(%{socket: socket, transport: transport}, {:thinking, text, opts}),
    do: transport_module(transport).send_thinking(socket, text, opts)

  defp send_openai(%{socket: socket, transport: transport}, {:instructions, text, opts}),
    do: transport_module(transport).send_instructions(socket, text, opts)

  defp send_openai(%{socket: socket, transport: transport}, {:tool_output, call_id, output}),
    do: transport_module(transport).send_tool_output(socket, call_id, output)

  defp send_openai(%{socket: socket, transport: transport}, :response_create),
    do: transport_module(transport).send_response_create(socket)
end
