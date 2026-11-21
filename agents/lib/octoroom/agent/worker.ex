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
  `Octoroom.Agent.Pipeline.Spec.default/1`):

    * **cascaded** (default): each front end streams to speech-to-text, and
      turns arrive as text.
    * **half-cascaded** (`Spec.default(stt: false)`): each front end records
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

  ## Changing front-end stages

  An `Octoroom.Agent.Frames.UpdateStage` that leaves the back end, from
  either end, goes to every front end, and to each one that starts later
  (with the latest options per stage). That's how a back-end stage changes
  the decision model's questions as a conversation moves on.

  It hears at 16 kHz mono and speaks at 24 kHz mono on its first output.

  ## Gemini Live and OpenAI Live

  With `Octoroom.Agent.Pipeline.Spec.gemini_live/1`
  (`Octoroom.Agent.Processors.GeminiLive`) or
  `Octoroom.Agent.Pipeline.Spec.openai_live/1`
  (`Octoroom.Agent.Processors.OpenAILive`) as the pipeline, one
  speech-to-speech model does everything. It has one audio input, so there
  are no front ends: the inputs are mixed (`Octoroom.Agent.Audio.Mixer`) and
  the back end hears a 20 ms chunk of the mix at a time. The model decides
  when to answer and when it's been interrupted, so `:respond`, `:gate` and
  follow-ups don't apply, and anyone can interrupt it. What it hears has no
  speakers: it tells voices apart as best it can, the conversation's user
  items have no `speaker`, and tools get `speaker: nil` (except for typed
  turns, which are sent as `[speaker] text`). It needs a voice, and
  `GOOGLE_API_KEY` (Gemini Live) or `OPENAI_API_KEY` (OpenAI Live).

  The model doesn't know when its audio has played, and generates faster
  than real time. So when it hears someone start a turn while its reply is
  still playing, the agent interrupts that reply itself, and the model
  thinks the whole reply was heard. There are no `:transcription`,
  `:decision`, `:waiting` or `:follow_up` events, and `say/3` asks the
  model to say the words, which it may not do exactly.

  Gemini Live keeps its session through dropped connections (the server
  closes each after 10 minutes or so) and through restarts: it saves the
  session's latest resumption handle (`save:`), and a restarted agent
  resumes with it. Gemini keeps a session for 2 hours after it ends. If the
  handle is older than that, or Gemini rejects it (or on OpenAI Live, which
  starts a new session on restart), the new session's instructions end with
  the conversation so far (the last 50 items), so the model still knows what
  was said, but not how it sounded. Either way, it doesn't greet again.

  ## Args (a map or keyword list)

  `Octoroom.Agent.agent/3` builds these from an `Octoroom.Agent` module:
  `:agent` (the module) and `:args` (its `ctx.args`), whose callbacks fill
  in `:instructions`, `:tools`, `:initial_text` and the pipelines. Given
  directly:

    * `:front_end`, `:back_end` - the pipeline specs, both needed (see
      `Octoroom.Agent.Pipeline.Spec.default/1`). Each front end has its own host for tasks
      and timers. `front_end: nil` mixes the inputs into the back end, as
      for Gemini Live. A `:tts` stage must produce 24 kHz and an `:stt`
      stage hear 16 kHz. With `gate: :decision`, a front end with no
      `:decisions` stage gets one at its end, with `:decisions` as its
      options: they must name a `:model`.
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

  ## Clients

  Participants subscribed to its first output (its voice, or its data
  output with `voice: false`) see it in their client (see
  `Octoroom.Worker`'s `presence:` and `notify:`; in the browser,
  `agents/priv/static/octoroom_agents.mjs`):

    * presence: `attributes` `name` and `description` (from `agents/2`),
      and `state`: `"listening"`, `"thinking"` (a reply started),
      `"speaking"` (its audio is playing; until the last of it has
      played), or `"waiting"` (holding a turn, see above)
    * `"transcript"` events: each conversation item as it changes,
      `message_id`, `sequence`, `role`, `text`, `status`, `interrupted`,
      and `speaker` and `source` for people
    * a `"transcript_snapshot"` (`%{items: [...]}`, the last
      `:snapshot_items`, default 50) to each participant as it subscribes
    * `"error"` events: `%{stage, fatal}`

  Decisions, waiting and latency stay server-side, as `emit`s.

  A client's `%{"text" => text}` message (`room.send/2`) is a turn from
  that participant that it always answers, whatever `:respond` and the gate
  say: typing to it is addressing it. It interrupts a reply as speaking
  would. Other payloads are ignored.
  """

  use Octoroom.Worker, audio: [rate: 16_000, channels: 1, output: [rate: 24_000]]

  require Logger

  alias Octoroom.Agent.Audio.Mixer
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.{Core, Host, Spec}

  @in_rate 16_000
  @out_rate 24_000
  # A mixed back end hears a chunk of its inputs' mix this often.
  @mix_ms 20

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
        # Options the back end set on front-end stages with `UpdateStage`,
        # by stage name, for front ends started later.
        front_updates: %{},
        # Mixed (no front end, as for Gemini Live): every input goes into
        # one mix, which the back end hears a chunk at a time. `mix_at` is
        # when the next chunk is due.
        mixer: if(front_spec == nil, do: Mixer.new(rate: @in_rate, chunk_ms: @mix_ms)),
        mix_at: nil,
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
        memory: restored(ctx.saved),
        # What clients are told (see "Clients" in the moduledoc): the
        # outputs it can notify on, its presence state and attributes, and
        # the timer that sets `listening` once a reply has played.
        outputs: ctx.outputs,
        data: ctx.data,
        presence: nil,
        attributes: attributes(name, args),
        presence_timer: nil,
        snapshot_items: Map.get(args, :snapshot_items, 50)
      }

      # `gate: nil` clears one shared by `agents/2`.
      if state.mixer && (args[:gate] != nil or args[:respond] != nil) do
        Logger.warning(
          "agent #{ctx.id}: the model takes its own turns when it hears a mix; " <>
            "gate: and respond: are ignored"
        )
      end

      {state, actions} = set_presence(state, "listening", [])
      {state, actions} = push_back(state, %Frames.Start{session_id: session_id(ctx)}, actions)

      {state, actions} =
        if state.mixer,
          do: {schedule_mix(%{state | mix_at: now()}), actions},
          else: Enum.reduce(ctx.inputs, {state, actions}, &add_front/2)

      result(state, actions)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_audio(input, pcm, %{mixer: %Mixer{} = mixer} = state),
    do: {:ok, %{state | mixer: Mixer.push(mixer, input, pcm)}}

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
  def handle_info({:octoroom, :inputs, inputs}, %{mixer: %Mixer{} = mixer} = state) do
    gone = Map.keys(mixer.inputs) -- inputs
    {:ok, %{state | mixer: Enum.reduce(gone, mixer, &Mixer.drop(&2, &1))}}
  end

  def handle_info({:octoroom, :inputs, inputs}, state) do
    {state, actions} = Enum.reduce(inputs -- Map.keys(state.fronts), {state, []}, &add_front/2)
    state = Enum.reduce(Map.keys(state.fronts) -- inputs, state, &drop_front/2)
    result(state, actions)
  end

  def handle_info({:octoroom, :outputs, outputs}, state), do: {:ok, %{state | outputs: outputs}}
  def handle_info({:octoroom, :data, data}, state), do: {:ok, %{state | data: data}}

  # Someone can now see it on its first output: catch them up on the
  # conversation. A restarted agent is told about everyone again.
  def handle_info({:octoroom, :subscribed, participant_id, output}, state) do
    case channels(state) do
      [^output | _] ->
        items =
          state.memory.items
          |> Enum.take(-state.snapshot_items)
          |> Enum.map(&client_item/1)

        snapshot = {output, "transcript_snapshot", %{items: items}, participant_id}
        {:ok, state, notify: snapshot}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:octoroom, :unsubscribed, _participant_id, _output}, state), do: {:ok, state}

  # Typed from a client (`room.send/2`). The room only lets through people
  # the agent hears. It's their turn, as if they'd said it, and always
  # answered: messaging the agent is addressing it.
  def handle_info({:octoroom, :message, participant_id, %{"text" => text}}, state)
      when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, state}
      text -> typed(participant_id, text, state)
    end
  end

  def handle_info({:octoroom, :message, participant_id, payload}, state) do
    Logger.debug(
      "agent #{state.id} ignored a message from #{participant_id}: #{inspect(payload)}"
    )

    {:ok, state}
  end

  # A reply's audio has played: it's listening again.
  def handle_info({:octoroom_agent_presence, ref}, %{presence_timer: ref} = state) do
    {state, actions} = set_presence(state, "listening", [])
    result(state, actions)
  end

  def handle_info({:octoroom_agent_presence, _stale}, state), do: {:ok, state}

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

    actions =
      [emit: {:agent, event}, save: state.memory] ++
        to_clients(state, "transcript", client_item(item))

    {:ok, state, actions}
  end

  def handle_info({:voice_pipeline, _from, event}, state),
    do: {:ok, state, emit: {:agent, event}}

  # The next chunk of the mix is due (and any that a late timer missed, up
  # to 100 ms; past that the mix skips ahead rather than burst).
  def handle_info(:octoroom_agent_mix, state) do
    late = now() - state.mix_at
    {chunks, mix_at} = if late >= 5 * @mix_ms, do: {1, now()}, else: {div(late, @mix_ms) + 1, nil}
    mix_at = mix_at || state.mix_at + (chunks - 1) * @mix_ms

    {state, actions} =
      Enum.reduce(1..chunks, {%{state | mix_at: mix_at}, []}, fn _, {state, actions} ->
        case Mixer.pull(state.mixer) do
          {nil, mixer} ->
            {%{state | mixer: mixer}, actions}

          {pcm, mixer} ->
            frame = %Frames.InputAudio{audio: pcm, sample_rate: @in_rate}
            push_back(%{state | mixer: mixer}, frame, actions)
        end
      end)

    result(schedule_mix(state), actions)
  end

  # A held turn's wait ran out with nobody else speaking: answer it.
  def handle_info({:octoroom_agent_floor, ref}, %{waiting: %{ref: ref} = w} = state) do
    wait_ms = max(now() - w.waited_from, 0)
    emit_floor_wait(state, w, wait_ms, :replied)
    actions = [emit: {:agent, {:waiting, nil}}]

    {state, actions} =
      commit(
        w.input,
        w.name,
        w.frame,
        true,
        %{state | waiting: nil},
        actions,
        wait_ms: wait_ms,
        decided_at: w.decided_at
      )

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

  defp schedule_mix(state) do
    at = state.mix_at + @mix_ms
    Process.send_after(self(), :octoroom_agent_mix, max(at - now(), 0))
    %{state | mix_at: at}
  end

  defp from_agent(%{agent: module} = args, ctx) when is_atom(module) do
    agent_ctx = agent_ctx(args, ctx)

    from_module = %{
      instructions: module.instructions(agent_ctx),
      tools: module.tools(agent_ctx),
      initial_text: if(ctx.resumed, do: nil, else: module.initial_text(agent_ctx))
    }

    case module.pipeline(agent_ctx) do
      {front, %Spec{} = back} when is_struct(front, Spec) or is_nil(front) ->
        args |> Map.merge(from_module) |> Map.merge(%{front_end: front, back_end: back})

      other ->
        raise ArgumentError,
              "#{inspect(module)}.pipeline/1 must return {front_end | nil, back_end}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp from_agent(args, _ctx), do: args

  # `voice: false`: no text-to-speech, so nothing to play, and the reply's
  # text is what was said.
  defp specs(args) do
    with {:ok, front, back} <- pipeline(args),
         :ok <- voice_for_mixed(front, args),
         :ok <- rate(back, :tts, :output_sample_rate, @out_rate, :unsupported_output_sample_rate),
         :ok <- rate(front, :stt, :sample_rate, @in_rate, :unsupported_input_sample_rate) do
      back =
        if Map.get(args, :voice, true) == false and :tts in Spec.names(back),
          do: back |> Spec.remove(:tts) |> silent_collector(),
          else: back

      with {:ok, front} <- with_decisions(front, args),
           do: {:ok, front, back, silence_ms(front)}
    end
  end

  defp pipeline(%{front_end: front, back_end: %Spec{} = back})
       when is_struct(front, Spec) or is_nil(front),
       do: {:ok, front, back}

  defp pipeline(_args), do: {:error, :no_pipeline}

  # The agent speaks at one rate and hears at another: a stage set to
  # anything else can't run. Left unset, the providers' defaults are these.
  defp rate(nil, _stage, _key, _rate, _error), do: :ok

  defp rate(spec, stage, key, rate, error) do
    case Keyword.get(Spec.opts(spec, stage) || [], key, rate) do
      ^rate -> :ok
      other -> {:error, {error, other}}
    end
  end

  # `gate: :decision` needs a decision stage in each front end.
  defp with_decisions(%Spec{} = front, %{gate: :decision} = args) do
    opts = Map.get(args, :decisions, [])

    cond do
      :decisions in Spec.names(front) ->
        {:ok, front}

      is_binary(opts[:model]) or is_function(opts[:evaluate]) ->
        {:ok, Spec.processor(front, :decisions, Octoroom.Agent.Processors.Decisions, opts)}

      true ->
        {:error, :decisions_need_a_model}
    end
  end

  defp with_decisions(front, _args), do: {:ok, front}

  # How long after someone stops talking the VAD says so.
  defp silence_ms(nil), do: 0

  defp silence_ms(front) do
    case Spec.opts(front, :vad) do
      nil -> 0
      opts -> Keyword.get(opts, :min_silence_ms, Octoroom.Agent.VAD.defaults().min_silence_ms)
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

  # A speech-to-speech model can't be silent.
  defp voice_for_mixed(nil, %{voice: false}), do: {:error, :voice_false_needs_text_to_speech}
  defp voice_for_mixed(_front, _args), do: :ok

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
      saved: if(restored?(ctx), do: Map.take(ctx.saved, [:history, :conversation])),
      # For Gemini Live: its session to resume, and what was said, for a
      # new session if it can't.
      resume: resume(ctx.saved)
    }
  end

  defp session_id(ctx), do: "#{ctx.room_id}/#{ctx.id}"

  @max_items 200

  # What was saved, with a reply that was playing when the agent stopped
  # marked interrupted: the rest of it was never heard.
  defp restored(%{history: history, conversation: conversation, items: items} = saved) do
    items =
      Enum.map(items, fn
        %{status: "playing"} = item ->
          Map.merge(item, %{status: "interrupted", interrupted: true})

        item ->
          item
      end)

    # Gemini Live's handle stays until the model sends a new one.
    Map.merge(Map.take(saved, [:gemini_handle]), %{
      history: history,
      conversation: conversation,
      items: items
    })
  end

  defp restored(_nothing), do: %{history: [], conversation: nil, items: []}

  # A cascaded agent's history, or a Gemini Live conversation.
  defp restored?(ctx),
    do: match?(%{history: [_ | _]}, ctx.saved) or resume(ctx.saved) != nil

  # Gemini keeps a session for 2 hours after it ends; a minute's margin.
  @handle_ms :timer.hours(2) - :timer.minutes(1)

  defp resume(%{items: items} = saved) do
    handle =
      case saved do
        %{gemini_handle: %{handle: handle, at: at}} ->
          if System.system_time(:millisecond) - at < @handle_ms, do: handle

        _ ->
          nil
      end

    if handle || match?(%{gemini_handle: _}, saved) || items != [],
      do: %{handle: handle, items: items}
  end

  defp resume(_nothing), do: nil

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
        acc = front_commands(input, commands, state, actions)

        Enum.reduce(state.front_updates, acc, fn {name, opts}, acc ->
          push_front(input, %Frames.UpdateStage{stage: name, opts: opts}, acc)
        end)

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

  # Into a front end from the back end's side.
  defp push_front(input, frame, {state, actions}) do
    {commands, core} = Core.push(state.fronts[input].core, frame, :upstream)
    state = put_in(state.fronts[input].core, core)
    front_commands(input, commands, state, actions)
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
    {state, actions ++ [emit: event] ++ error_to_clients(state, error)}
  end

  defp front_command(input, {:output_upstream, %Frames.UpdateStage{stage: name}}, acc) do
    Logger.warning("agent #{elem(acc, 0).id} (#{input}): no stage #{inspect(name)} to update")
    acc
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
    decided_at = now()

    event = %{
      source: input,
      speaker: name,
      text: Map.get(frame, :text),
      outcome: outcome,
      why: why,
      decision: frame.decision
    }

    emit_turn_decided(state, event, decided_at)
    actions = actions ++ [emit: {:agent, {:decision, event}}]

    case outcome do
      :reply -> commit(input, name, frame, true, state, actions, decided_at: decided_at)
      :listen -> commit(input, name, frame, false, state, actions)
      :wait -> wait(input, name, frame, decided_at, state, actions)
    end
  end

  # Into the back end, as a reply-starting turn or as history.
  defp commit(input, name, frame, respond?, state, actions, opts \\ []) do
    seq = state.seq + 1

    {state, actions} =
      if respond? do
        committed_at = now()
        speech_end = Map.get(state.vad_stop, input, committed_at)
        decided_at = Keyword.get(opts, :decided_at, committed_at)
        wait_ms = Keyword.get(opts, :wait_ms, 0)

        state = %{
          state
          | addressee: input,
            addressee_name: name,
            last_reply: nil,
            back: %{state.back | core: Core.put_telemetry(state.back.core, :turn_id, seq)},
            turn: %{
              id: seq,
              speech_end: speech_end,
              decided_at: decided_at,
              transcript: committed_at,
              wait_ms: wait_ms
            }
        }

        # Any follow-up window is used up: a reply is on its way.
        closed = if mode(state) == :addressed, do: [emit: {:agent, {:follow_up, nil}}], else: []
        tell_speaker(state, input, actions ++ closed)
      else
        {state, actions}
      end

    frame = %{frame | turn_id: seq, speaker: name, respond: respond?}
    {state, actions} = push_back(%{state | seq: seq}, frame, actions)
    if respond?, do: set_presence(state, "thinking", actions), else: {state, actions}
  end

  # Unsure: hold the turn for `wait_ms`. If nobody speaks, answer it.
  defp wait(input, name, frame, decided_at, state, actions) do
    ref = make_ref()
    ms = state.thresholds.wait_ms
    Process.send_after(self(), {:octoroom_agent_floor, ref}, ms)

    waiting = %{
      input: input,
      name: name,
      frame: frame,
      ref: ref,
      waited_from: now(),
      decided_at: decided_at
    }

    event = {:agent, {:waiting, %{source: input, speaker: name, ms: ms}}}
    set_presence(%{state | waiting: waiting}, "waiting", actions ++ [emit: event])
  end

  # Someone spoke (or another turn came) before the wait ran out: the held
  # turn goes into the conversation without a reply.
  defp end_wait(%{waiting: nil} = state, actions), do: {state, actions}

  defp end_wait(%{waiting: w} = state, actions) do
    emit_floor_wait(state, w, max(now() - w.waited_from, 0), :yielded)
    actions = actions ++ [emit: {:agent, {:waiting, nil}}]
    {state, actions} = commit(w.input, w.name, w.frame, false, %{state | waiting: nil}, actions)

    if state.presence == "waiting",
      do: set_presence(state, "listening", actions),
      else: {state, actions}
  end

  # Mixed: the model decides for itself.
  defp mode(%{mixer: %Mixer{}}), do: :always
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
    {state, actions} = set_presence(state, "thinking", actions ++ closed)
    tell_back(state, {:octoroom_agent_speaker, nil}, actions)
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

    set_presence(
      %{state | speaking_until: until},
      "speaking",
      [play: {:default, audio}] ++ latency
    )
  end

  defp back_command({:output, %Frames.OutputAudio{sample_rate: rate}}, state) do
    Logger.warning("agent #{state.id} dropped #{rate} Hz audio; it plays #{@out_rate} Hz")
    {state, []}
  end

  # Options for a stage that isn't in the back end (the decision model's
  # questions, say): every front end gets them, now and when it starts.
  defp back_command({direction, %Frames.UpdateStage{} = frame}, state)
       when direction in [:output, :output_upstream] do
    merge = &Keyword.merge(&1, frame.opts)
    state = update_in(state.front_updates, &Map.update(&1, frame.stage, frame.opts, merge))

    Enum.reduce(Map.keys(state.fronts), {state, []}, &push_front(&1, frame, &2))
  end

  defp back_command({:output, _frame}, state), do: {state, []}

  defp back_command({:output_upstream, %Frames.Error{} = error}, state) do
    Logger.warning(
      "agent #{state.id}: #{inspect(error.processor)} failed: #{inspect(error.reason)}"
    )

    event = {:agent, {:error, %{stage: error.processor, fatal: error.fatal?}}}
    {state, [emit: event] ++ error_to_clients(state, error)}
  end

  defp back_command({:output_upstream, _frame}, state), do: {state, []}
  # A mixed back end heard someone start a turn. If its reply is still
  # playing, they're talking over it.
  defp back_command({:notify, :user_speaking}, state) do
    if now() < state.speaking_until,
      do: push_back(state, %Frames.Interruption{}, []),
      else: {state, []}
  end

  defp back_command({:notify, event}, state), do: {state, [emit: {:agent, event}]}

  defp back_command({:interrupted, _generation}, state),
    do: set_presence(%{state | turn: nil, speaking_until: now()}, "listening", flush: :default)

  defp back_command({:observe, %Frames.LLMText{}}, %{turn: %{} = turn} = state)
       when not is_map_key(turn, :llm),
       do: {%{state | turn: Map.put(turn, :llm, now())}, []}

  # The reply's text is done; its audio may play for a while yet. The
  # follow-up window starts when it stops.
  defp back_command({:observe, %Frames.AssistantMessage{}}, state) do
    at = max(now(), state.speaking_until)
    state = %{state | last_reply: {state.addressee, at}}
    {state, listening} = listening_at(state, at)

    if mode(state) == :addressed and state.addressee do
      window = %{
        source: state.addressee,
        speaker: state.addressee_name,
        ms: at - now() + state.follow_up_ms
      }

      {state, listening ++ [emit: {:agent, {:follow_up, window}}]}
    else
      {state, listening}
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

  # -- Clients --

  defp attributes(name, args) do
    case Map.get(args, :description) do
      d when is_binary(d) and d != "" -> %{name: name, description: d}
      _ -> %{name: name}
    end
  end

  # What it can notify on: its outputs, then its data outputs.
  defp channels(state), do: state.outputs ++ state.data

  # Its presence, if it changed. Any change cancels a pending `listening`.
  defp set_presence(state, status, actions) do
    state = %{state | presence_timer: nil}

    if state.presence == status,
      do: {state, actions},
      else:
        {%{state | presence: status},
         actions ++ [presence: %{state: status, attributes: state.attributes}]}
  end

  # When a reply's audio will have played (now, if it has).
  defp listening_at(state, at) do
    case at - now() do
      ms when ms <= 0 ->
        set_presence(state, "listening", [])

      ms ->
        ref = make_ref()
        Process.send_after(self(), {:octoroom_agent_presence, ref}, ms)
        {%{state | presence_timer: ref}, []}
    end
  end

  # `notify:` on its first output, if it has one to notify on.
  defp to_clients(state, type, data) do
    if channels(state) == [], do: [], else: [notify: {:default, type, data}]
  end

  defp error_to_clients(state, error),
    do: to_clients(state, "error", %{stage: inspect(error.processor), fatal: error.fatal?})

  # What clients see of a conversation item: strings and numbers only.
  defp client_item(item),
    do:
      Map.take(item, [
        :message_id,
        :sequence,
        :role,
        :text,
        :status,
        :interrupted,
        :speaker,
        :source,
        :at
      ])

  defp typed(participant_id, text, state) do
    input =
      Enum.find(Map.keys(state.fronts), &(participant_id(&1) == participant_id)) ||
        "#{participant_id}/mic"

    {name, state} = speaker(input, state)
    {state, actions} = end_wait(state, [])

    {state, actions} =
      if may_interrupt?(input, state),
        do: push_back(state, %Frames.Interruption{}, actions),
        else: {state, actions}

    event = %{
      source: input,
      speaker: name,
      text: text,
      outcome: :reply,
      why: :typed,
      decision: nil
    }

    actions = actions ++ [emit: {:agent, {:decision, event}}]
    # Latency is measured from now, not from the speaker's last VAD stop.
    state = update_in(state.vad_stop, &Map.delete(&1, input))
    emit_turn_decided(state, event, now())
    frame = %Frames.Transcription{text: text, source: input}
    {state, actions} = commit(input, name, frame, true, state, actions)
    result(state, actions)
  end

  # -- Latency --

  defp now, do: System.monotonic_time(:millisecond)

  defp emit_turn_decided(state, event, decided_at) do
    speech_end = Map.get(state.vad_stop, event.source, decided_at)

    measurements =
      %{
        system_time: System.system_time(),
        monotonic_time: System.monotonic_time(),
        speech_to_decided_ms: max(decided_at - speech_end, 0)
      }
      |> then(fn m ->
        case event.decision do
          %{latency_ms: ms} when is_number(ms) -> Map.put(m, :decision_ms, ms)
          _ -> m
        end
      end)

    :telemetry.execute(
      [:octoroom_agent, :turn, :decided],
      measurements,
      %{
        room_id: state.room_id,
        agent_id: state.id,
        input: event.source,
        speaker: event.speaker,
        text: event.text,
        outcome: event.outcome,
        why: event.why,
        decision: event.decision
      }
    )
  end

  defp emit_floor_wait(state, waiting, duration_ms, outcome) do
    :telemetry.execute(
      [:octoroom_agent, :turn, :floor_wait],
      %{
        duration_ms: duration_ms,
        system_time: System.system_time(),
        monotonic_time: System.monotonic_time()
      },
      %{
        room_id: state.room_id,
        agent_id: state.id,
        input: waiting.input,
        speaker: waiting.name,
        outcome: outcome
      }
    )
  end

  defp first_audio(%{turn: %{speech_end: speech_end, transcript: transcript} = turn} = state) do
    transcript_ms = transcript - speech_end
    llm_ms = if(turn[:llm], do: turn.llm - speech_end)
    audio_ms = now() - speech_end
    wait_ms = Map.get(turn, :wait_ms, 0)
    decided_at = Map.get(turn, :decided_at, transcript)

    latency = %{
      transcript: transcript_ms,
      llm: llm_ms,
      audio: audio_ms
    }

    measurements =
      %{
        transcript_ms: transcript_ms,
        audio_ms: audio_ms,
        wait_ms: wait_ms,
        processing_ms: max(audio_ms - wait_ms, 0),
        stt_and_decision_ms: max(decided_at - speech_end, 0)
      }
      |> then(fn m -> if llm_ms, do: Map.put(m, :llm_ms, llm_ms), else: m end)

    :telemetry.execute(
      [:octoroom_agent, :turn, :latency],
      measurements,
      %{
        room_id: state.room_id,
        agent_id: state.id,
        turn_id: turn[:id],
        input: state.addressee,
        speaker: state.addressee_name
      }
    )

    Logger.info(
      "agent #{state.id} latency: transcript=#{latency.transcript}ms " <>
        "llm=#{latency.llm}ms audio=#{latency.audio}ms"
    )

    {%{state | turn: nil}, [emit: {:agent, {:latency, latency}}]}
  end

  defp first_audio(state), do: {state, []}
end
