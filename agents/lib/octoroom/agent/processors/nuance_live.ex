defmodule Octoroom.Agent.Processors.NuanceLive do
  @moduledoc """
  Nuance Live real-time audiovisual AI persona as one stage: `InputAudio` in,
  `OutputAudio` (24 kHz mono PCM16) and `OutputVideo` (encoded WebRTC RTP) out.

  The persona speaks and animates in full duplex inside a Nuance LiveKit room;
  this processor bridges audio, video RTP, keyframe (PLI) requests, transcripts,
  typed messages, and function tools (`delegation: [model: "default", ...]`)
  with Octoroom's room pipeline.

  Options:
    * `:persona` - `"sam"` (default), `"sonia"`, or `"mira"`
    * `:api_key` - Nuance API key (`nk_...`), default `NUANCE_API_KEY`
    * `:expressiveness` - optional number in `0..2` (default `1`)
    * `:delegation` - `:none`, `:client`, `[model: "default", ...]`, or raw map
      (defaults to `responses` delegation with `model: "default"` when the agent
      defines tools, or `:none` otherwise)
    * `:runtime_tools` - `[stay_quiet: true, end_call: false, call_time: false]`
    * `:timezone` - optional IANA timezone string (e.g. `"Europe/London"`)
    * `:max_session_seconds` - optional max duration in seconds
    * `:green_screen` - boolean (default `false`)
    * `:end_user_id` - optional end-user identifier for Nuance safety isolation
    * `:base_url` - API base URL (default `"https://api.nuancelabs.ai"`)
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Audio.PCM16
  alias Octoroom.Agent.ConversationEvents
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.NuanceLive.{Protocol, Session}
  alias Octoroom.Agent.Restore
  alias Octoroom.Agent.ToolExecutor
  alias Octoroom.Agent.ToolResult

  @output_sample_rate 24_000
  @user_idle_ms 800

  @impl true
  def init(opts, ctx) do
    persona = Protocol.persona(Keyword.get(opts, :persona))
    expressiveness = Protocol.expressiveness(Keyword.get(opts, :expressiveness))
    tools = Keyword.get(opts, :tools, Map.get(ctx, :tools, []))
    instructions = Keyword.get(opts, :instructions, Map.get(ctx, :instructions))
    restore = Restore.normalize(Keyword.get(opts, :restore, Map.get(ctx, :restore, true)))
    resume = if restore.enabled?, do: Map.get(ctx, :resume) || %{}, else: %{}

    delegation = Protocol.delegation(Keyword.get(opts, :delegation), tools)
    runtime_tools = Protocol.runtime_tools(Keyword.get(opts, :runtime_tools))

    end_user_id =
      Keyword.get(opts, :end_user_id) ||
        case Map.get(ctx, :session_id) do
          id when is_binary(id) -> "octoroom:#{id}"
          _ -> nil
        end

    setup =
      [
        persona: persona,
        expressiveness: expressiveness,
        instructions:
          Restore.with_transcript(
            instructions,
            resume[:items],
            resume[:tool_results],
            restore,
            resume != %{}
          ),
        delegation: delegation,
        tools: tools,
        runtime_tools: runtime_tools,
        end_user_id: end_user_id
      ] ++
        Keyword.take(opts, [
          :timezone,
          :max_session_seconds,
          :green_screen,
          :camera,
          :camera_input
        ])

    responses_delegation? =
      match?(%{type: "responses"}, delegation) or match?(%{"type" => "responses"}, delegation)

    state = %{
      send: Keyword.get(opts, :send),
      persona: persona,
      responses_delegation?: responses_delegation?,
      telemetry: Map.get(ctx, :telemetry, %{}),
      connect_started_at: now(),
      user_turn: nil,
      response: nil,
      session: nil,
      reply_to: Map.get(ctx, :runner) || self(),
      tools: tools,
      context: Keyword.get(opts, :context, Map.get(ctx, :context, %{})) || %{},
      initial_text: Keyword.get(opts, :initial_text, Map.get(ctx, :initial_text)),
      out_resample: nil,
      started?: false,
      session_started?: false,
      sent_initial_text?: false,
      generating?: false,
      discard?: false,
      hearing?: false,
      last_user_transcript_at: nil,
      user_idle_timer?: false,
      # Tool call batching: wait for BOTH step `response.completed` AND all tool calls finished.
      pending_tool_calls: MapSet.new(),
      completed_tool_outputs: [],
      step_completed?: false,
      owner: Map.get(ctx, :owner),
      last_video_input: nil,
      conversation_events: ConversationEvents.new()
    }

    case ctx do
      %{runner: runner} when is_pid(runner) and is_nil(state.send) ->
        with {:ok, api_key} <- api_key(opts),
             {:ok, session} <-
               Session.start_link(
                 [api_key: api_key, parent: runner, setup: setup] ++
                   Keyword.take(opts, [:base_url, :webrtc_opts])
               ) do
          {:ok, %{state | session: session}}
        end

      _test ->
        send_nuance(state, {:connect, [setup: setup]})
        {:ok, state}
    end
  end

  defp api_key(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("NUANCE_API_KEY")

    if is_binary(key) and key != "",
      do: {:ok, key},
      else: {:error, {:missing_env, "NUANCE_API_KEY"}}
  end

  # -- Frames from the agent --

  @impl true
  def handle_frame(%Frames.InputAudio{audio: audio, sample_rate: rate}, :downstream, state) do
    if state.session_started? or state.session != nil do
      send_nuance(state, {:audio, audio, sample_rate: rate})
    end

    {[], state}
  end

  def handle_frame(
        %Frames.InputVideo{packet: %ExRTP.Packet{} = packet, source: source, codec: codec},
        :downstream,
        state
      ) do
    if state.session_started? or state.session != nil do
      send_nuance(state, {:video, packet, codec})
    end

    {[], %{state | last_video_input: source || state.last_video_input}}
  end

  def handle_frame(%Frames.Start{} = frame, :downstream, state) do
    state = %{state | started?: true}
    {[{:push, frame, :downstream}], maybe_send_initial_text(state)}
  end

  def handle_frame(%Frames.Interruption{} = frame, :downstream, state) do
    state =
      if state.generating? do
        send_nuance(state, {:json, Protocol.interrupt_frame()})
        state |> emit_response_stop(:interrupted) |> commit_assistant(:interrupted)
      else
        state
      end

    state =
      if state.generating?,
        do: %{state | generating?: false, discard?: true},
        else: state

    {[{:push, frame, :downstream}], state}
  end

  def handle_frame(%Frames.Transcription{text: text} = frame, :downstream, state)
      when is_binary(text) do
    message = if frame.speaker, do: "[#{frame.speaker}] #{text}", else: text

    if state.responses_delegation? do
      send_nuance(state, {:json, Protocol.user_message_item_frame(message)})
      send_nuance(state, {:json, Protocol.response_create_frame()})
    else
      send_nuance(state, {:json, Protocol.commentary_append_frame(message)})
      send_nuance(state, {:json, Protocol.response_create_frame()})
    end

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
    send_nuance(state, {:json, Protocol.instructions_append_frame(text)})
    send_nuance(state, {:json, Protocol.response_create_frame()})
    {[{:notify, {:status, "Thinking"}}], %{state | discard?: false}}
  end

  def handle_frame(%Frames.LLMText{text: text}, :downstream, state) do
    send_nuance(
      state,
      {:json, Protocol.commentary_append_frame("Say this to the user right now: " <> text)}
    )

    send_nuance(state, {:json, Protocol.response_create_frame()})
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
  def handle_timer(:user_idle, %{last_user_transcript_at: nil} = state),
    do: {[], %{state | user_idle_timer?: false}}

  def handle_timer(:user_idle, state) do
    case @user_idle_ms - (now() - state.last_user_transcript_at) do
      left when left > 0 ->
        {[{:timer, :user_idle, left}], state}

      _idle ->
        state = %{state | hearing?: false, user_idle_timer?: false}
        {[], state}
    end
  end

  def handle_timer(_key, state), do: {[], state}

  # -- From Nuance Live session, PLI requests, and tool results --

  @impl true
  def handle_info({:nuance_live_socket, event}, state), do: event(event, state)

  def handle_info(:octoroom_video_pli, state) do
    send_nuance(state, :request_keyframe)
    {[], state}
  end

  def handle_info({:octoroom_agent_speaker, speaker}, state),
    do: {[], %{state | context: Map.put(state.context, :speaker, speaker)}}

  def handle_info({:octoroom_agent_frames, frames}, state),
    do: {[], %{state | context: Map.put(state.context, :frames, frames)}}

  def handle_info({:octoroom_agent_async_tool_result, %{response: response} = result}, state) do
    if is_pid(state.owner) do
      send(state.owner, {:voice_pipeline, self(), {:tool_result, ToolResult.summary(result)}})
    end

    pending = MapSet.delete(state.pending_tool_calls, result.call_id)
    outputs = [{result.call_id, response} | state.completed_tool_outputs]

    state = %{state | pending_tool_calls: pending, completed_tool_outputs: outputs}
    state = maybe_flush_tool_results(state)

    events = if result.event, do: [{:notify, {:control, result.event}}], else: []
    {events, state}
  end

  def handle_info(_message, state), do: {[], state}

  @impl true
  def terminate(_reason, %{session: session}) when is_pid(session) do
    Session.close(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Nuance Live events --

  defp event(:connected, state), do: {[], state}

  defp event(:camera_pli, %{last_video_input: input} = state) when is_binary(input),
    do: {[{:notify, {:request_pli, input}}], state}

  defp event(:camera_pli, state), do: {[], state}

  defp event({:status, status}, state), do: {[{:notify, {:status, status}}], state}

  defp event({:session_started, _session}, state) do
    dur = if state.connect_started_at, do: max(now() - state.connect_started_at, 0)
    emit_session(state, :started, if(dur, do: %{duration_ms: dur}, else: %{}))
    state = %{state | session_started?: true, connect_started_at: nil}
    {[], maybe_send_initial_text(state)}
  end

  defp event({:video_rtp, %ExRTP.Packet{} = packet, codec}, state) do
    {[{:push, %Frames.OutputVideo{packet: packet, codec: codec}, :downstream}], state}
  end

  defp event({:video_rtp, %ExRTP.Packet{} = packet}, state) do
    {[{:push, %Frames.OutputVideo{packet: packet}, :downstream}], state}
  end

  defp event({:audio, _pcm, _rate}, %{discard?: true} = state), do: {[], state}

  defp event({:audio, pcm, sample_rate: rate}, state) do
    {out_pcm, resample} =
      PCM16.resample_stream(pcm, rate, @output_sample_rate, state.out_resample)

    ts = now()

    state =
      state
      |> ensure_response_started(ts)
      |> record_response_audio(out_pcm, ts)
      |> Map.merge(%{
        generating?: true,
        hearing?: false,
        out_resample: resample
      })

    if out_pcm == <<>> do
      {[], state}
    else
      frame = %Frames.OutputAudio{audio: out_pcm, sample_rate: @output_sample_rate}
      {[{:push, frame, :downstream}], state}
    end
  end

  defp event({:transcription_delta, :user, text}, state) do
    ts = now()
    state = state |> ConversationEvents.append(:user, text) |> track_user_turn(text, ts)

    {notify, state} =
      if String.trim(text) != "" and not state.hearing? and not state.generating?,
        do: {[{:notify, :user_speaking}], %{state | hearing?: true}},
        else: {[], state}

    {timers, state} = ensure_user_idle_timer(%{state | last_user_transcript_at: ts})
    {notify ++ timers, state}
  end

  defp event({:transcription_done, :user, text, _meta}, state) do
    state =
      state
      |> ConversationEvents.replace(:user, text)
      |> ConversationEvents.commit(:user, :completed)
      |> Map.put(:hearing?, false)

    {[], state}
  end

  defp event({:transcription, :assistant, _text}, %{discard?: true} = state), do: {[], state}

  defp event({:transcription, :assistant, text}, state) do
    ts = now()

    state =
      state
      |> ConversationEvents.commit(:user, :completed)
      |> ConversationEvents.append(:assistant, text)
      |> ensure_response_started(ts)
      |> Map.merge(%{generating?: true, hearing?: false})

    {[], state}
  end

  defp event({:output_audio_done, reason, _frame}, state) do
    text = assistant_text(state)

    status =
      case reason do
        "interrupted" -> :interrupted
        "revised" -> :interrupted
        _ -> :completed
      end

    state =
      if state.generating? do
        state
        |> emit_response_stop(if(status == :completed, do: :ok, else: :interrupted))
        |> commit_assistant(status)
      else
        state
      end

    state = %{state | generating?: false, discard?: false}

    {[
       {:push, %Frames.AssistantMessage{text: text, interrupted?: status != :completed},
        :downstream}
     ], state}
  end

  defp event({:tool_call, _delegation_id, calls}, state) do
    ids = for call <- calls, is_binary(call[:id]), do: call.id
    pending = Enum.reduce(ids, state.pending_tool_calls, &MapSet.put(&2, &1))
    ToolExecutor.run_async(calls, state.tools, state.context, reply_to: state.reply_to)
    {[], %{state | pending_tool_calls: pending}}
  end

  defp event({:response_completed, _delegation_id, _inner}, state) do
    state = maybe_flush_tool_results(%{state | step_completed?: true})
    {[], state}
  end

  defp event({:delegation_created, delegation}, state),
    do: {[{:notify, {:delegation, delegation}}], state}

  defp event({:error, error}, state) do
    Logger.warning("Nuance Live error: #{inspect(error)}")
    emit_session(state, :error, %{}, %{reason: error})
    fatal? = fatal_error?(error)
    frame = %Frames.Error{processor: __MODULE__, reason: error, fatal?: fatal?}
    {[{:push, frame, :upstream}], state}
  end

  defp event({:session_closed, reason, _frame}, state) do
    Logger.info("Nuance Live session closed: #{inspect(reason)}")
    emit_session(state, :closed, %{}, %{reason: reason})
    state = finish_open_turns(state, :completed)
    {[], %{state | session_started?: false, generating?: false, discard?: false, hearing?: false}}
  end

  defp event({:conversation_ended, reason}, state) do
    Logger.info("Nuance Live conversation ended: #{inspect(reason)}")
    emit_session(state, :closed, %{}, %{reason: reason})
    state = finish_open_turns(state, :completed)
    {[], %{state | session_started?: false, generating?: false, discard?: false, hearing?: false}}
  end

  defp event({:disconnected, reason}, state) do
    Logger.warning("Nuance Live disconnected: #{inspect(reason)}")
    emit_session(state, :disconnected, %{}, %{reason: reason})
    state = finish_open_turns(state, :failed)
    frame = %Frames.Error{processor: __MODULE__, reason: {:disconnected, reason}, fatal?: true}

    {[{:notify, {:status, "Disconnected"}}, {:push, frame, :upstream}],
     %{
       state
       | session_started?: false,
         generating?: false,
         discard?: false,
         hearing?: false,
         pending_tool_calls: MapSet.new(),
         completed_tool_outputs: [],
         step_completed?: false
     }}
  end

  defp event(_event, state), do: {[], state}

  defp fatal_error?({kind, _, _})
       when kind in [:session_token_failed, :conversation_failed],
       do: true

  defp fatal_error?({kind, _})
       when kind in [:session_token_failed, :conversation_failed, :livekit_signal],
       do: true

  defp fatal_error?(_other), do: false

  defp finish_open_turns(state, status) do
    state = ConversationEvents.commit(state, :user, status)

    if state.generating?,
      do:
        state
        |> emit_response_stop(if(status == :failed, do: :error, else: :ok))
        |> commit_assistant(status),
      else: state
  end

  defp maybe_flush_tool_results(
         %{step_completed?: true, completed_tool_outputs: [_ | _] = outputs} = state
       ) do
    if MapSet.size(state.pending_tool_calls) == 0 do
      outputs
      |> Enum.reverse()
      |> Enum.each(fn {call_id, response} ->
        send_nuance(state, {:json, Protocol.tool_output_frame(call_id, response)})
      end)

      send_nuance(state, {:json, Protocol.response_create_frame()})
      %{state | completed_tool_outputs: [], step_completed?: false}
    else
      state
    end
  end

  defp maybe_flush_tool_results(%{step_completed?: true, completed_tool_outputs: []} = state) do
    if MapSet.size(state.pending_tool_calls) == 0,
      do: %{state | step_completed?: false},
      else: state
  end

  defp maybe_flush_tool_results(state), do: state

  defp maybe_send_initial_text(
         %{sent_initial_text?: false, started?: true, session_started?: true} = state
       )
       when is_binary(state.initial_text) and state.initial_text != "" do
    send_nuance(state, {:json, Protocol.response_create_frame(instructions: state.initial_text)})
    %{state | sent_initial_text?: true}
  end

  defp maybe_send_initial_text(state), do: state

  defp ensure_user_idle_timer(%{user_idle_timer?: true} = state), do: {[], state}

  defp ensure_user_idle_timer(state),
    do: {[{:timer, :user_idle, @user_idle_ms}], %{state | user_idle_timer?: true}}

  defp assistant_text(state) do
    case get_in(state, [:conversation_events, :pending, :assistant]) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp commit_assistant(state, status),
    do: ConversationEvents.commit(state, :assistant, status)

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
    ended_at = now()
    duration_ms = max(ended_at - r.started_at, 0)
    duration = System.convert_time_unit(duration_ms, :millisecond, :native)

    latency_ms =
      if r.user_last_at && r.first_audio_at, do: max(r.first_audio_at - r.user_last_at, 0)

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
      provider: :nuance,
      model: "nuance_live",
      voice: state.persona,
      transport: :livekit
    })
    |> Map.merge(extra)
  end

  defp send_nuance(%{send: send}, message) when is_function(send, 1), do: send.(message)
  defp send_nuance(%{session: nil}, _message), do: :ok

  defp send_nuance(%{session: pid}, {:audio, audio, opts}),
    do: Session.send_audio(pid, audio, opts)

  defp send_nuance(%{session: pid}, {:video, packet, codec}),
    do: Session.send_video(pid, packet, codec)

  defp send_nuance(%{session: pid}, {:json, frame}),
    do: Session.send_json(pid, frame)

  defp send_nuance(%{session: pid}, :request_keyframe),
    do: Session.request_keyframe(pid)
end
