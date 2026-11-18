defmodule Octoroom.Agent.Worker do
  @moduledoc ~S"""
  Runs an agent as an Octoroom worker: one process per agent, hearing any
  number of people. Usually started by `Octoroom.Agent.agent/3` from an
  `Octoroom.Agent` module:

      def workers(%{participants: []}), do: []

      def workers(room) do
        [agent("assistant", MyApp.Assistant, hears: Enum.map(room.participants, &mic/1))]
      end

  It can also be added with `worker/3` and the args below:

      worker("assistant", Octoroom.Agent.Worker,
        inputs: Enum.map(room.participants, &mic/1),
        outputs: ["assistant"],
        args: %{name: "Assistant", instructions: "You help a team on a call. Be brief."}
      )

  ## Many speakers, one conversation

  Each input gets its own front end, so each person has their own VAD and
  turn detection and nothing is mixed. The speaker is known from the input
  a turn came in on, not from the voice, so it assumes one person per mic.
  Their finished turns go into one back end, labelled with the speaker's
  name: the LLM sees
  `[Priya] can you add Acme to the sheet`. People joining and leaving add
  and drop front ends without restarting the agent. Two pipelines (see
  `Octoroom.Agent.Pipeline.Spec.cascaded_split/2`):

    * **cascaded** (default): each front end streams to speech-to-text, and
      turns arrive as text.
    * **half-cascaded** (`backend: %{stt: false}`): each front end records
      whole turns as audio (Smart Turn decides when a turn ends), and the
      LLM hears them, after a `[speaker]` label. A transcriber turns each
      into text in the background, for the history and the transcript.

  ## Deciding to answer

  Every turn goes into the conversation. Whether it also starts a reply
  depends on `:respond`:

    * `:always` - every turn. The default with one input.
    * `:addressed` - turns that say the agent's `:name` (as a word, any
      case; text turns only), and follow-ups: a turn from the person it
      last answered within `:follow_up_ms` after it stops talking, or
      before that reply is done. With the decision gate, the model can
      still turn a follow-up down (see below). The default with several inputs, or with
      the decision gate. Half-cascaded turns are audio, so the name never
      matches and only follow-ups reply: use `gate: :decision` there.
    * `:never` - none.

  With `gate: :decision`, each front end also asks a decision model about
  each turn's audio (`Octoroom.Agent.Processors.Decisions`): who the
  speaker is talking to, and whether an assistant could answer. When
  neither the name nor a follow-up settles it, `:thresholds` do:

    * the assistant's probability is at least `reply_above` (0.7): reply;
    * at least `wait_above` (0.35), or it's aimed at the group or nobody and
      answerable at least `answer_above` (0.7): wait `wait_ms` (2.5 s), and
      reply if nobody starts talking in the meantime;
    * otherwise: listen.

  A follow-up gets the same reading, except that waiting counts as
  replying: it replies unless the model says listen. So the person it just
  answered can carry on without the name, but turning to someone else
  ("Bob, can you share your screen?") doesn't get an answer.

  A turn with no decision (the call failed or took too long) falls back to
  the name and follow-ups.

  Only the person the agent is answering can interrupt it (with one input
  and `:always`, that's always them). Two people talking over it don't cut
  it off.

  It hears at 16 kHz mono and speaks at 24 kHz mono on its first output.

  ## Args (a map or keyword list)

  `Octoroom.Agent.agent/3` builds these from an `Octoroom.Agent` module:
  `:agent` (the module) and `:args` (its `ctx.args`), whose callbacks fill
  in `:instructions`, `:tools`, `:backend`, `:initial_text` and the
  pipelines. Given directly:

    * `:backend` - a `Octoroom.Agent.Backend.Cascaded` struct, or a map for
      `Octoroom.Agent.Backend.Cascaded.new/1` (default `%{}`: Soniox, Gemini
      through ReqLLM, Inworld). Its text-to-speech must produce 24 kHz.
    * `:front_end`, `:back_end` - pipeline specs to run instead of the
      backend's (see `Octoroom.Agent.Pipeline.Spec.cascaded_split/2`). Each
      front end has its own host for tasks and timers.
    * `:name` (default `"Assistant"`), `:respond`, `:follow_up_ms` (default
      10 s), `:gate` (`:name`, the default, or `:decision`), `:thresholds`,
      `:decisions` (options for the decision stage) - see above
    * `:instructions`, `:initial_text`, `:tools` - read by the context and
      tools stages
    * `:tool_context` - the map tool handlers receive (`room_id`,
      `agent_id`, and `speaker`, the participant whose turn started the
      reply, are added)
    * `:voice` - `false` runs no text-to-speech

  It also takes `{:octoroom_agent, :say, text}`,
  `{:octoroom_agent, :prompt, text}` and `{:octoroom_agent, :interrupt}`
  messages (see `Octoroom.Agent.say/3` and the others).

  Speakers are named from participants' `join/2` metadata (`:name`), or
  their id. Provider keys come from the environment: `SONIOX_API_KEY`,
  `INWORLD_API_KEY`, and whatever ReqLLM reads for the LLM
  (`GOOGLE_API_KEY` for Gemini).

  ## Events

  The worker `emit`s, to the room's `scope: :room` subscribers
  (`Octoroom.subscribe/2`):

    * `{:agent, {:conversation, item}}` - a finished item (see
      `Octoroom.Agent.ConversationEvents`); user items carry `speaker` and
      `source` (the input track). A spoken reply comes twice with the same
      `message_id`: `"playing"`, then `"completed"`, or `"interrupted"`
      with only what was heard.
    * `{:agent, {:transcription, %{status, text, source, speaker}}}` -
      cascaded only: partial and final transcripts of each input, for
      captions. Half-cascaded sends `{:agent, {:transcription, %{status:
      "final", text}}}` per turn from the transcriber, with no `source` or
      `speaker` and usually after the reply has started; the matching
      `:conversation` item has both.
    * `{:agent, {:follow_up, %{source, speaker, ms} | nil}}` - with
      `:addressed`, when a reply finishes: for the next `ms` (the rest of
      the reply's audio plus `:follow_up_ms`), `speaker` can carry on
      without saying the name. `nil` when a new reply starts.
    * `{:agent, {:decision, %{source, speaker, text, outcome, why, decision}}}`
      - per turn: `outcome` is `:reply`, `:wait` or `:listen`, `why` says
      which rule decided (`:name`, `:follow_up`, `:addressed`,
      `:maybe_addressed`, `:open_question`, `:not_addressed`, `:always`,
      `:never`), and `decision` is the model's answers or nil
    * `{:agent, {:waiting, %{source, speaker, ms} | nil}}` - a turn is held
      for `ms` to see if anyone else answers; `nil` when that's settled
    * `{:agent, {:latency, %{transcript, llm, audio}}}` - per reply, ms from
      `speech_end` (below) to the turn reaching the back end (`transcript`:
      the final transcript when cascaded, the recorded turn when
      half-cascaded), the first LLM text, and the first audio handed to the
      outlet
    * `{:agent, event}` - the back end's other notifications, such as
      `{:status, "Thinking"}`

  `speech_end` is when that speaker's VAD reported they stopped, minus its
  `min_silence_ms`. What the browser adds after the outlet isn't included.
  """

  use Octoroom.Worker, audio: [rate: 16_000, channels: 1, output: [rate: 24_000]]

  require Logger

  alias Octoroom.Agent.Backend.Cascaded
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.{Core, Host, Spec}

  @in_rate 16_000
  @out_rate 24_000

  # The decision gate's defaults (see "Deciding to answer" in the moduledoc).
  @thresholds %{reply_above: 0.7, wait_above: 0.35, answer_above: 0.7, wait_ms: 2_500}

  @impl true
  def init(args, ctx) do
    args = args |> Map.new() |> with_roster(ctx) |> from_agent(ctx) |> with_questions(ctx)

    with {:ok, front_spec, back_spec, silence_ms} <- specs(args),
         {:ok, back_core} <- Core.new(back_spec, back_ctx(args, ctx)) do
      name = Map.get(args, :name, "Assistant")

      state = %{
        id: ctx.id,
        room_id: ctx.room_id,
        back: %{
          core: Core.observe(back_core, [Frames.LLMText, Frames.AssistantMessage]),
          host: Host.new()
        },
        fronts: %{},
        front_spec: front_spec,
        people: people(ctx.participants),
        name_pattern: name_pattern(name),
        # The other agents' names: a turn naming one of them isn't a
        # follow-up for this one.
        other_names: for(a <- args.roster, a.id != ctx.id, do: name_pattern(a.name)),
        # For `decide/2`: the agent module, if any, and its ctx.
        agent: Map.get(args, :agent),
        decide_ctx: decide_ctx(args, ctx),
        respond: Map.get(args, :respond),
        follow_up_ms: Map.get(args, :follow_up_ms, 10_000),
        gate: Map.get(args, :gate, :name),
        thresholds: thresholds(args),
        # A turn held while the agent waits to see if anyone else answers:
        # %{input, name, frame, ref}.
        waiting: nil,
        silence_ms: silence_ms,
        seq: 0,
        addressee: nil,
        addressee_name: nil,
        last_reply: nil,
        # When the audio handed to the outlet will have played (the outlet
        # plays in real time). Outlets don't report playback yet. Monotonic
        # time can be negative, so it starts at now, not 0.
        speaking_until: now(),
        vad_stop: %{},
        turn: nil,
        # Saved (`save:`) for the next start: the context stage's memory and
        # the conversation items.
        memory: restored(ctx.saved)
      }

      {state, actions} = push_back(state, %Frames.Start{session_id: session_id(ctx)}, [])
      {state, actions} = Enum.reduce(ctx.inputs, {state, actions}, &add_front/2)
      result(state, actions)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_audio(input, pcm, state) do
    {state, actions} =
      if Map.has_key?(state.fronts, input), do: {state, []}, else: add_front(input, {state, []})

    case state.fronts[input] do
      nil ->
        {:ok, state}

      front ->
        frame = %Frames.InputAudio{audio: pcm, source: input, sample_rate: @in_rate}
        {commands, core} = Core.push(front.core, frame)
        state = put_in(state.fronts[input].core, core)
        {state, actions} = front_commands(input, commands, state, actions)
        result(state, actions)
    end
  end

  @impl true
  def handle_info({:octoroom, :inputs, inputs}, state) do
    {state, actions} = Enum.reduce(inputs -- Map.keys(state.fronts), {state, []}, &add_front/2)
    state = Enum.reduce(Map.keys(state.fronts) -- inputs, state, &drop_front/2)
    result(state, actions)
  end

  def handle_info({:octoroom, :outputs, _outputs}, state), do: {:ok, state}

  # From `Octoroom.Agent.say/3`: the words go straight to text-to-speech, as
  # a reply of their own.
  def handle_info({:octoroom_agent, :say, text}, state) do
    {state, actions} = app_turn(state, [])
    {state, actions} = push_back(state, %Frames.Interruption{}, actions)

    {state, actions} =
      Enum.reduce(
        [%Frames.LLMResponseStart{}, %Frames.LLMText{text: text}, %Frames.LLMResponseEnd{}],
        {state, actions},
        fn frame, {state, actions} -> push_back(state, frame, actions) end
      )

    result(state, actions)
  end

  def handle_info({:octoroom_agent, :prompt, text}, state) do
    {state, actions} = app_turn(state, [])
    {state, actions} = push_back(state, %Frames.Prompt{text: text}, actions)
    result(state, actions)
  end

  def handle_info({:octoroom_agent, :interrupt}, state) do
    {state, actions} = push_back(state, %Frames.Interruption{}, [])
    result(state, actions)
  end

  # After an interruption flushed the output: how much of the reply's audio
  # never played, so the collector knows how much of it was heard.
  def handle_info({:octoroom, :flushed, _output, dropped_ms}, state) do
    {state, actions} = push_back(state, %Frames.AudioFlushed{dropped_ms: dropped_ms}, [])
    result(state, actions)
  end

  # What the context stage would need to carry on after a restart.
  def handle_info({:voice_pipeline, _from, {:memory, memory}}, state) do
    state = %{state | memory: Map.merge(state.memory, memory)}
    {:ok, state, save: state.memory}
  end

  # Conversation items, sent by the context stage to its owner (this
  # process): kept with the memory, for `Octoroom.Agent.conversation/2`.
  def handle_info({:voice_pipeline, _from, {:conversation, item} = event}, state) do
    state = update_in(state.memory.items, &put_item(&1, item))
    {:ok, state, emit: {:agent, event}, save: state.memory}
  end

  def handle_info({:voice_pipeline, _from, event}, state),
    do: {:ok, state, emit: {:agent, event}}

  # A held turn's wait ran out with nobody else speaking: answer it.
  def handle_info({:octoroom_agent_floor, ref}, %{waiting: %{ref: ref} = w} = state) do
    actions = [emit: {:agent, {:waiting, nil}}]
    {state, actions} = commit(w.input, w.name, w.frame, true, %{state | waiting: nil}, actions)
    result(state, actions)
  end

  def handle_info({:octoroom_agent_floor, _stale}, state), do: {:ok, state}

  # Linked helpers (STT sockets, HTTP streams) exiting: the worker traps
  # exits, and the stages that care hear about it from their own sockets.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:ok, state}

  # A front end's tasks and timers carry its input in their ids.
  def handle_info({:octoroom_agent_task, {:front, input, _id}, _msg} = message, state),
    do: front_message(input, message, state)

  def handle_info({:octoroom_agent_timer, {:front, input, _id}} = message, state),
    do: front_message(input, message, state)

  # The back end's tasks and timers, then a task that died without reporting
  # (back end or any front end). Anything else, such as an STT socket's
  # events, goes to every stage of every pipeline; each STT stage picks out
  # its own socket's.
  def handle_info(message, state) do
    with :unknown <- Host.handle_message(state.back.host, state.back.core, message),
         :unknown <- down_in_front(message, state) do
      broadcast(message, state)
    else
      {commands, core, host} ->
        state = %{state | back: %{core: core, host: host}}
        {state, actions} = back_commands(commands, state, [])
        result(state, actions)

      {:front, input, commands, front} ->
        state = put_in(state.fronts[input], front)
        {state, actions} = front_commands(input, commands, state, [])
        result(state, actions)
    end
  end

  defp front_message(input, message, state) do
    case state.fronts[input] do
      nil ->
        {:ok, state}

      front ->
        case Host.handle_message(front.host, front.core, message, &untag/1) do
          {commands, core, host} ->
            state = put_in(state.fronts[input], %{core: core, host: host})
            {state, actions} = front_commands(input, commands, state, [])
            result(state, actions)

          :unknown ->
            {:ok, state}
        end
    end
  end

  defp down_in_front({:DOWN, _, :process, _, _} = message, state) do
    Enum.find_value(state.fronts, :unknown, fn {input, front} ->
      case Host.handle_message(front.host, front.core, message, &untag/1) do
        {commands, core, host} -> {:front, input, commands, %{core: core, host: host}}
        :unknown -> nil
      end
    end)
  end

  defp down_in_front(_message, _state), do: :unknown

  defp untag({:front, _input, id}), do: id

  defp broadcast(message, state) do
    {state, actions} =
      Enum.reduce(state.fronts, {state, []}, fn {input, front}, {state, actions} ->
        {commands, core} = Core.info(front.core, :broadcast, message)
        state = put_in(state.fronts[input].core, core)
        front_commands(input, commands, state, actions)
      end)

    {commands, core} = Core.info(state.back.core, :broadcast, message)
    state = put_in(state.back.core, core)
    {state, actions} = back_commands(commands, state, actions)
    result(state, actions)
  end

  @impl true
  def terminate(reason, state) do
    Enum.each(Map.keys(state.fronts), &drop_front(&1, state))
    commands = Core.terminate(state.back.core, reason)
    host = Enum.reduce(commands, state.back.host, &elem(Host.execute(&2, &1), 1))
    Host.stop(host)
    :ok
  end

  # -- Setup --

  # An `Octoroom.Agent` module's callbacks fill in the args they cover.
  defp name_pattern(name), do: ~r/\b#{Regex.escape(name)}\b/i

  defp thresholds(args), do: Map.merge(@thresholds, Map.new(Map.get(args, :thresholds, %{})))

  # The agents in the room (`Octoroom.Agent.agents/2`), or just this one.
  defp with_roster(args, ctx) do
    me = %{
      id: ctx.id,
      name: Map.get(args, :name, "Assistant"),
      description: Map.get(args, :description)
    }

    roster =
      case Map.get(args, :roster) do
        [_ | _] = roster -> Enum.map(roster, &Map.merge(%{description: nil}, Map.new(&1)))
        _ -> [me]
      end

    Map.put(args, :roster, roster)
  end

  defp agent_ctx(args, ctx) do
    %{
      room_id: ctx.room_id,
      agent_id: ctx.id,
      name: Map.get(args, :name, "Assistant"),
      roster: args.roster,
      participants: ctx.participants,
      resumed: ctx.resumed,
      args: Map.get(args, :args, %{})
    }
  end

  defp decide_ctx(args, ctx), do: Map.put(agent_ctx(args, ctx), :thresholds, thresholds(args))

  # The decision model's questions: `decisions: [questions: ...]` if given,
  # else the agent module's, else the defaults for the roster.
  defp with_questions(%{gate: :decision} = args, ctx) do
    opts = Map.get(args, :decisions, [])

    questions =
      Keyword.get_lazy(opts, :questions, fn ->
        agent_ctx = agent_ctx(args, ctx)

        case Map.get(args, :agent) do
          module when is_atom(module) and module != nil -> module.questions(agent_ctx)
          _ -> Octoroom.Agent.default_questions(agent_ctx)
        end
      end)

    Map.put(args, :decisions, Keyword.put(opts, :questions, questions))
  end

  defp with_questions(args, _ctx), do: args

  defp from_agent(%{agent: module} = args, ctx) when is_atom(module) do
    agent_ctx = agent_ctx(args, ctx)

    from_module = %{
      instructions: module.instructions(agent_ctx),
      tools: module.tools(agent_ctx),
      backend: module.backend(agent_ctx),
      initial_text: if(ctx.resumed, do: nil, else: module.initial_text(agent_ctx))
    }

    from_module =
      case module.pipeline(agent_ctx) do
        {%Spec{} = front, %Spec{} = back} ->
          Map.merge(from_module, %{front_end: front, back_end: back})

        nil ->
          from_module
      end

    Map.merge(args, from_module)
  end

  defp from_agent(args, _ctx), do: args

  # `voice: false`: no text-to-speech, so nothing to play, and the reply's
  # text is what was said.
  defp specs(args) do
    with {:ok, front, back, silence_ms} <- voiced_specs(args) do
      back =
        if Map.get(args, :voice, true) == false and :tts in Spec.names(back),
          do: back |> Spec.remove(:tts) |> silent_collector(),
          else: back

      {:ok, front, back, silence_ms}
    end
  end

  defp silent_collector(back) do
    if :collector in Spec.names(back),
      do:
        Spec.replace(
          back,
          :collector,
          Spec.processor(:collector, Octoroom.Agent.Processors.AssistantCollector, voice: false)
        ),
      else: back
  end

  defp voiced_specs(%{front_end: %Spec{} = front, back_end: %Spec{} = back}),
    do: {:ok, front, back, 0}

  defp voiced_specs(args) do
    backend =
      case Map.get(args, :backend, %{}) do
        %Cascaded{} = backend -> backend
        opts -> Cascaded.new(opts)
      end

    rate = Map.get(backend.text_to_speech, :output_sample_rate)
    stt_rate = Map.get(backend.speech_to_text, :sample_rate)

    cond do
      rate != @out_rate ->
        {:error, {:unsupported_output_sample_rate, rate}}

      stt_rate != @in_rate ->
        {:error, {:unsupported_input_sample_rate, stt_rate}}

      true ->
        vad? = backend.vad.enabled or Cascaded.audio_input?(backend)
        silence_ms = if vad?, do: backend.vad.min_silence_ms, else: 0

        split_opts =
          if Map.get(args, :gate) == :decision,
            do: [decisions: Map.get(args, :decisions, [])],
            else: []

        {front, back} = Spec.cascaded_split(backend, split_opts)
        {:ok, front, back, silence_ms}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp back_ctx(args, ctx) do
    tool_context =
      args
      |> Map.get(:tool_context, %{})
      |> Map.merge(%{room_id: ctx.room_id, agent_id: ctx.id, speaker: nil})

    %{
      runner: self(),
      owner: self(),
      session_id: session_id(ctx),
      telemetry: %{room_id: ctx.room_id, agent_id: ctx.id},
      instructions: Map.get(args, :instructions),
      # Carrying on a conversation: no greeting.
      initial_text: if(restored?(ctx), do: nil, else: Map.get(args, :initial_text)),
      tools: Map.get(args, :tools, []),
      context: tool_context,
      saved: if(restored?(ctx), do: Map.take(ctx.saved, [:history, :conversation]))
    }
  end

  defp session_id(ctx), do: "#{ctx.room_id}/#{ctx.id}"

  @max_items 200

  # What was saved, with a reply that was playing when the agent stopped
  # marked interrupted: the rest of it was never heard.
  defp restored(%{history: history, conversation: conversation, items: items}) do
    items =
      Enum.map(items, fn
        %{status: "playing"} = item ->
          Map.merge(item, %{status: "interrupted", interrupted: true})

        item ->
          item
      end)

    %{history: history, conversation: conversation, items: items}
  end

  defp restored(_nothing), do: %{history: [], conversation: nil, items: []}

  defp restored?(ctx), do: match?(%{history: [_ | _]}, ctx.saved)

  # The latest version of each item, in the order they started, with when
  # each was first seen (`at`, unix ms).
  defp put_item(items, item) do
    case Enum.find_index(items, &(&1.message_id == item.message_id)) do
      nil ->
        Enum.take(items ++ [Map.put(item, :at, System.system_time(:millisecond))], -@max_items)

      index ->
        List.update_at(items, index, &Map.merge(item, Map.take(&1, [:at])))
    end
  end

  # -- Front ends: one per input --

  defp add_front(input, {state, actions}) do
    ctx = %{
      runner: self(),
      session_id: "#{state.room_id}/#{state.id}/#{input}",
      telemetry: %{room_id: state.room_id, agent_id: state.id, input: input}
    }

    case Core.new(state.front_spec, ctx) do
      {:ok, core} ->
        core = Core.observe(core, [Frames.VADUserStoppedSpeaking])
        state = put_in(state.fronts[input], %{core: core, host: Host.new()})
        {commands, core} = Core.push(core, %Frames.Start{session_id: ctx.session_id})
        state = put_in(state.fronts[input].core, core)
        front_commands(input, commands, state, actions)

      {:error, reason} ->
        Logger.warning("agent #{state.id} can't hear #{input}: #{inspect(reason)}")
        {state, actions}
    end
  end

  defp drop_front(input, state) do
    case Map.pop(state.fronts, input) do
      {nil, _} ->
        state

      {front, fronts} ->
        host =
          front.core
          |> Core.terminate(:normal)
          |> Enum.reduce(front.host, &elem(Host.execute(&2, tag(input, &1)), 1))

        Host.stop(host)
        %{state | fronts: fronts, vad_stop: Map.delete(state.vad_stop, input)}
    end
  end

  defp front_commands(input, commands, state, actions),
    do: Enum.reduce(commands, {state, actions}, &front_command(input, &1, &2))

  defp front_command(
         input,
         {:output, %Frames.Transcription{text: text} = frame},
         {state, actions}
       )
       when is_binary(text) and text != "",
       do: turn(input, frame, state, actions)

  defp front_command(input, {:output, %Frames.UserAudio{} = frame}, {state, actions}),
    do: turn(input, frame, state, actions)

  # Someone started talking: the agent stops if they're the one it's
  # answering, and a turn it's waiting on gets an answer from a person.
  defp front_command(input, {:output, %Frames.UserStartedSpeaking{} = frame}, {state, actions}) do
    {state, actions} = end_wait(state, actions)
    {state, actions} = push_back(state, frame, actions)

    if may_interrupt?(input, state),
      do: push_back(state, %Frames.Interruption{}, actions),
      else: {state, actions}
  end

  defp front_command(_input, {:output, %Frames.UserStoppedSpeaking{} = frame}, {state, actions}),
    do: push_back(state, frame, actions)

  defp front_command(_input, {:output, _frame}, acc), do: acc
  defp front_command(_input, {:interrupted, _generation}, acc), do: acc

  defp front_command(input, {:notify, {:transcription, map}}, {state, actions}) do
    {name, state} = speaker(input, state)
    event = {:agent, {:transcription, Map.merge(map, %{source: input, speaker: name})}}
    {state, actions ++ [emit: event]}
  end

  defp front_command(_input, {:notify, _event}, acc), do: acc

  defp front_command(input, {:observe, %Frames.VADUserStoppedSpeaking{}}, {state, actions}),
    do: {put_in(state.vad_stop[input], now() - state.silence_ms), actions}

  defp front_command(_input, {:observe, _frame}, acc), do: acc

  defp front_command(input, {:output_upstream, %Frames.Error{} = error}, {state, actions}) do
    Logger.warning(
      "agent #{state.id} (#{input}): #{inspect(error.processor)} failed: #{inspect(error.reason)}"
    )

    event = {:agent, {:error, %{stage: error.processor, fatal: error.fatal?, source: input}}}
    {state, actions ++ [emit: event]}
  end

  defp front_command(_input, {:output_upstream, _frame}, acc), do: acc

  # Tasks and timers run on the front end's own host, with ids tagged by
  # input so they can't collide with another pipeline's.
  defp front_command(input, command, {state, actions}) do
    front = state.fronts[input]

    case Host.execute(front.host, tag(input, command)) do
      {:ok, host} ->
        {put_in(state.fronts[input].host, host), actions}

      :unhandled ->
        Logger.warning("agent #{state.id} (#{input}) ignored command #{inspect(command)}")
        {state, actions}
    end
  end

  defp tag(input, {:start_task, id, fun}), do: {:start_task, {:front, input, id}, fun}
  defp tag(input, {:start_timer, id, ms}), do: {:start_timer, {:front, input, id}, ms}
  defp tag(input, {op, id}) when op in [:kill_task, :cancel_timer], do: {op, {:front, input, id}}
  defp tag(_input, command), do: command

  # A finished turn from `input`: into the conversation, and maybe a reply.
  defp turn(input, frame, state, actions) do
    {name, state} = speaker(input, state)
    {state, actions} = end_wait(state, actions)
    {outcome, why} = outcome(input, frame, state)

    event = %{
      source: input,
      speaker: name,
      text: Map.get(frame, :text),
      outcome: outcome,
      why: why,
      decision: frame.decision
    }

    actions = actions ++ [emit: {:agent, {:decision, event}}]

    case outcome do
      :reply -> commit(input, name, frame, true, state, actions)
      :listen -> commit(input, name, frame, false, state, actions)
      :wait -> wait(input, name, frame, state, actions)
    end
  end

  # Into the back end, as a reply-starting turn or as history.
  defp commit(input, name, frame, respond?, state, actions) do
    seq = state.seq + 1

    {state, actions} =
      if respond? do
        speech_end = Map.get(state.vad_stop, input, now())

        state = %{
          state
          | addressee: input,
            addressee_name: name,
            last_reply: nil,
            turn: %{speech_end: speech_end, transcript: now()}
        }

        # Any follow-up window is used up: a reply is on its way.
        closed = if mode(state) == :addressed, do: [emit: {:agent, {:follow_up, nil}}], else: []
        tell_speaker(state, input, actions ++ closed)
      else
        {state, actions}
      end

    frame = %{frame | turn_id: seq, speaker: name, respond: respond?}
    push_back(%{state | seq: seq}, frame, actions)
  end

  # Unsure: hold the turn for `wait_ms`. If nobody speaks, answer it.
  defp wait(input, name, frame, state, actions) do
    ref = make_ref()
    ms = state.thresholds.wait_ms
    Process.send_after(self(), {:octoroom_agent_floor, ref}, ms)
    waiting = %{input: input, name: name, frame: frame, ref: ref}
    event = {:agent, {:waiting, %{source: input, speaker: name, ms: ms}}}
    {%{state | waiting: waiting}, actions ++ [emit: event]}
  end

  # Someone spoke (or another turn came) before the wait ran out: the held
  # turn goes into the conversation without a reply.
  defp end_wait(%{waiting: nil} = state, actions), do: {state, actions}

  defp end_wait(%{waiting: w} = state, actions) do
    actions = actions ++ [emit: {:agent, {:waiting, nil}}]
    commit(w.input, w.name, w.frame, false, %{state | waiting: nil}, actions)
  end

  defp mode(%{respond: nil, gate: :decision}), do: :addressed
  defp mode(%{respond: nil, fronts: fronts}) when map_size(fronts) > 1, do: :addressed
  defp mode(%{respond: nil}), do: :always
  defp mode(%{respond: respond}), do: respond

  # `{:reply | :wait | :listen, why}`. The name and a follow-up need no
  # model; the decision gate then reads the turn's `decision`.
  defp outcome(input, frame, state) do
    text = Map.get(frame, :text)
    named = fn pattern -> is_binary(text) and Regex.match?(pattern, text) end

    case mode(state) do
      :always ->
        {:reply, :always}

      :never ->
        {:listen, :never}

      :addressed ->
        decision = if state.gate == :decision, do: Map.get(frame, :decision)

        named? = named.(state.name_pattern)
        turn = %{source: input, speaker: nil, text: text, decision: decision, named: named?}

        cond do
          # With a decision, the name goes to `decide/2` too, so an agent
          # can turn down what it's asked by name (the default doesn't).
          named? and decision != nil -> decide(turn, state)
          named? -> {:reply, :name}
          Enum.any?(state.other_names, named) -> {:listen, :named_other}
          follow_up?(input, state) -> follow_up(turn, state)
          decision != nil -> decide(turn, state)
          true -> {:listen, :not_addressed}
        end
    end
  end

  # A follow-up replies at once, unless the decision model hears it aimed
  # elsewhere: someone the assistant just answered turning to the team.
  # Anything the model would reply to or wait on counts, since the speaker
  # was just talking to the assistant.
  defp follow_up(%{decision: nil}, _state), do: {:reply, :follow_up}

  defp follow_up(turn, state) do
    case decide(turn, state) do
      {:listen, why} -> {:listen, why}
      _reply_or_wait -> {:reply, :follow_up}
    end
  end

  # The agent module's `decide/2`, or the default. A raise counts as the
  # default, so a bug in the app's rule doesn't restart the agent.
  defp decide(turn, state) do
    turn = %{turn | speaker: speaker_name(turn.source, state)}

    result =
      case state.agent do
        nil ->
          Octoroom.Agent.decide(turn, state.decide_ctx)

        module ->
          try do
            module.decide(turn, state.decide_ctx)
          rescue
            error ->
              Logger.error(
                "#{inspect(module)}.decide/2 raised: " <>
                  Exception.format(:error, error, __STACKTRACE__)
              )

              Octoroom.Agent.decide(turn, state.decide_ctx)
          end
      end

    case result do
      outcome when outcome in [:reply, :wait, :listen] ->
        {outcome, :decided}

      {outcome, why} when outcome in [:reply, :wait, :listen] ->
        {outcome, why}

      other ->
        Logger.error("decide/2 must return :reply, :wait or :listen, got: #{inspect(other)}")
        Octoroom.Agent.decide(turn, state.decide_ctx)
    end
  end

  defp speaker_name(input, state) do
    case state.people[participant_id(input)] do
      nil -> input
      person -> display_name(person)
    end
  end

  # `at` is when the reply finishes playing, so it may still be ahead.
  defp follow_up?(input, %{last_reply: {input, at}} = state), do: now() - at <= state.follow_up_ms

  # The person it's answering, before that reply is done: they're still
  # talking to it ("Assistant." … "what's the time?" split at a pause).
  defp follow_up?(input, %{addressee: input, last_reply: nil}) when input != nil, do: true
  defp follow_up?(_input, _state), do: false

  defp may_interrupt?(input, state), do: mode(state) == :always or input == state.addressee

  # -- Speakers --

  defp people(participants), do: Map.new(participants, &{&1.id, &1})

  defp display_name(%{meta: %{name: name}}) when is_binary(name), do: name
  defp display_name(%{meta: %{"name" => name}}) when is_binary(name), do: name
  defp display_name(%{id: id}), do: id

  # Inputs are `<participant id>/<source>`.
  defp participant_id(input), do: input |> String.split("/") |> hd()

  # A participant who joined after the agent started is looked up in the
  # room once.
  defp speaker(input, state) do
    id = participant_id(input)

    state =
      if Map.has_key?(state.people, id),
        do: state,
        else: %{state | people: Map.merge(state.people, current_people(state.room_id))}

    case state.people do
      %{^id => person} -> {display_name(person), state}
      _ -> {input, state}
    end
  end

  defp current_people(room_id) do
    case Octoroom.Room.state(room_id) do
      %{participants: participants} -> people(participants)
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # Before a reply, the tools stage learns who asked. Metadata can change
  # during a call (`update_meta/3`), and tools authorize against it, so it's
  # read fresh from the room.
  defp tell_speaker(state, input, actions) do
    id = participant_id(input)
    state = %{state | people: Map.merge(state.people, current_people(state.room_id))}
    tell_back(state, {:octoroom_agent_speaker, Map.get(state.people, id)}, actions)
  end

  # A reply the app started: nobody on the call asked, so nobody has the
  # floor to follow up or interrupt.
  defp app_turn(state, actions) do
    closed =
      if mode(state) == :addressed and state.addressee,
        do: [emit: {:agent, {:follow_up, nil}}],
        else: []

    state = %{state | addressee: nil, addressee_name: nil, last_reply: nil, turn: nil}
    tell_back(state, {:octoroom_agent_speaker, nil}, actions ++ closed)
  end

  defp tell_back(state, message, actions) do
    {commands, core} = Core.info(state.back.core, :broadcast, message)
    back_commands(commands, put_in(state.back.core, core), actions)
  end

  # -- Back end --

  defp push_back(state, frame, actions) do
    {commands, core} = Core.push(state.back.core, frame)
    back_commands(commands, put_in(state.back.core, core), actions)
  end

  defp back_commands(commands, state, actions) do
    Enum.reduce(commands, {state, actions}, fn command, {state, actions} ->
      {state, more} = back_command(command, state)
      {state, actions ++ more}
    end)
  end

  defp back_command({:output, %Frames.OutputAudio{sample_rate: @out_rate, audio: audio}}, state) do
    {state, latency} = first_audio(state)
    # 24 kHz mono s16le: 48 bytes per ms.
    until = max(now(), state.speaking_until) + div(byte_size(audio), 48)
    {%{state | speaking_until: until}, [play: {:default, audio}] ++ latency}
  end

  defp back_command({:output, %Frames.OutputAudio{sample_rate: rate}}, state) do
    Logger.warning("agent #{state.id} dropped #{rate} Hz audio; it plays #{@out_rate} Hz")
    {state, []}
  end

  defp back_command({:output, _frame}, state), do: {state, []}

  defp back_command({:output_upstream, %Frames.Error{} = error}, state) do
    Logger.warning(
      "agent #{state.id}: #{inspect(error.processor)} failed: #{inspect(error.reason)}"
    )

    {state, [emit: {:agent, {:error, %{stage: error.processor, fatal: error.fatal?}}}]}
  end

  defp back_command({:output_upstream, _frame}, state), do: {state, []}
  defp back_command({:notify, event}, state), do: {state, [emit: {:agent, event}]}

  defp back_command({:interrupted, _generation}, state),
    do: {%{state | turn: nil, speaking_until: now()}, [flush: :default]}

  defp back_command({:observe, %Frames.LLMText{}}, %{turn: %{} = turn} = state)
       when not is_map_key(turn, :llm),
       do: {%{state | turn: Map.put(turn, :llm, now())}, []}

  # The reply's text is done; its audio may play for a while yet. The
  # follow-up window starts when it stops.
  defp back_command({:observe, %Frames.AssistantMessage{}}, state) do
    at = max(now(), state.speaking_until)
    state = %{state | last_reply: {state.addressee, at}}

    if mode(state) == :addressed and state.addressee do
      window = %{
        source: state.addressee,
        speaker: state.addressee_name,
        ms: at - now() + state.follow_up_ms
      }

      {state, [emit: {:agent, {:follow_up, window}}]}
    else
      {state, []}
    end
  end

  defp back_command({:observe, _frame}, state), do: {state, []}

  defp back_command(command, state) do
    case Host.execute(state.back.host, command) do
      {:ok, host} ->
        {put_in(state.back.host, host), []}

      :unhandled ->
        Logger.warning("agent #{state.id} ignored command #{inspect(command)}")
        {state, []}
    end
  end

  defp result(state, []), do: {:ok, state}
  defp result(state, actions), do: {:ok, state, actions}

  # -- Latency --

  defp now, do: System.monotonic_time(:millisecond)

  defp first_audio(%{turn: %{speech_end: speech_end, transcript: transcript} = turn} = state) do
    latency = %{
      transcript: transcript - speech_end,
      llm: if(turn[:llm], do: turn.llm - speech_end),
      audio: now() - speech_end
    }

    Logger.info(
      "agent #{state.id} latency: transcript=#{latency.transcript}ms " <>
        "llm=#{latency.llm}ms audio=#{latency.audio}ms"
    )

    {%{state | turn: nil}, [emit: {:agent, {:latency, latency}}]}
  end

  defp first_audio(state), do: {state, []}
end
