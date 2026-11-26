defmodule Octoroom.Agent do
  @moduledoc ~S"""
  A voice agent in a room: a module with instructions and tools, added to a
  room's `workers/1` with `agent/3`.

      defmodule MyApp.Assistant do
        use Octoroom.Agent

        @impl true
        def instructions(ctx) do
          "You're on a team call for #{ctx.args.workspace}. " <>
            "Several people are talking; each line starts with the speaker's name. Be brief."
        end

        @impl true
        def tools(_ctx), do: [MyApp.Sheets.add_row(), MyApp.Sheets.update_cell()]

        @impl true
        def pipeline(_ctx) do
          Octoroom.Agent.Pipeline.Spec.default(
            stt: "soniox:stt-rt-v6",
            llm: [provider: :google, model: "gemini-3.5-flash", reasoning_effort: :minimal],
            tts: "inworld:inworld-tts-2"
          )
        end
      end

      defmodule MyApp.TeamRoom do
        use Octoroom.Room
        import Octoroom.Agent, only: [agent: 3]

        @impl true
        def workers(room) do
          [
            agent("assistant", MyApp.Assistant,
              hears: Enum.map(room.participants, &mic/1),
              respond: :addressed,
              args: %{workspace: room.assigns.workspace}
            )
          ]
        end
      end

  Every callback gets `ctx`: `room_id`, `agent_id`, `name`, `participants`
  (when the agent started), `resumed` (see `Octoroom.Worker.Context`),
  `args` (from `agent/3`) and `roster` (the agents in the room, see
  `agents/2`). Only `pipeline/1` is needed: it names the providers and
  models, and nothing picks them for you.

  ## Deciding to answer

  With `gate: :decision` and `decisions: [model: "google:gemini-decision-1"]`,
  each turn's audio goes to that decision model with
  `questions/1`, and `decide/2` reads the answers. The defaults ask who the
  speaker is talking to (each agent by name, a person, the group, nobody)
  and whether the agent could answer, and reply, wait or listen by the
  agent's `:thresholds`. Override either to ask about something else:

      @impl true
      def questions(ctx) do
        Map.put(Octoroom.Agent.default_questions(ctx), "capital", %{
          type: :boolean,
          instructions: "Is this a question about a capital city?"
        })
      end

      @impl true
      def decide(turn, ctx) do
        if get_in(turn.decision.answers, ["capital", "probability"]) >= 0.6,
          do: Octoroom.Agent.decide(turn, ctx),
          else: {:listen, :not_about_capitals}
      end

  `turn.named` says the turn used the agent's name; the default replies to
  it, and a `decide/2` like the one above can still say no. Follow-ups are
  checked first, and only `:listen` turns one down (see
  `Octoroom.Agent.Worker`).

  ## Several agents

  `agents/2` adds several to a room. Each knows the others (`ctx.roster`),
  so the decision model is asked which of them a turn is for, by name and
  `:description`, and an open question goes to the one best placed to
  answer it.

  An agent runs as an `Octoroom.Agent.Worker`; its moduledoc has the
  details of turn-taking and the events it emits.

  ## Tools

  Tool handlers run in the agent's process, on the app's node, so they call
  the app directly. Their context has `room_id`, `agent_id` and `speaker`:
  the participant whose turn started the reply (nil when the app started it
  with `prompt/3`). `join/2` metadata is set by the server, so
  `speaker.meta` can be trusted for authorization.
  """

  alias Octoroom.Agent.Pipeline.Spec

  @type ctx :: %{
          room_id: String.t(),
          agent_id: String.t(),
          participants: [Octoroom.Participant.t()],
          resumed: nil | %{gone_ms: non_neg_integer},
          args: term
        }

  @doc "The system prompt."
  @callback instructions(ctx) :: String.t() | nil

  @doc "The tools the LLM may call (`Octoroom.Agent.Tool` structs)."
  @callback tools(ctx) :: [%Octoroom.Agent.Tool{}]

  @doc """
  Prompt sent to the model as soon as the agent starts so it generates an
  opening reply ("Greet the visitor"). Mirrors `Octoroom.Agent.prompt/3`.
  Not used when the agent restarts during a room's recovery (`ctx.resumed`)
  or carries on a saved conversation, so it doesn't greet twice.
  """
  @callback initial_prompt(ctx) :: String.t() | nil

  @doc """
  Words spoken verbatim as soon as the agent starts, straight to
  text-to-speech (like `Octoroom.Agent.say/3`). Takes precedence over
  `initial_prompt/1` if both are set. Not used on `ctx.resumed` or restored
  conversations.
  """
  @callback initial_say(ctx) :: String.t() | nil

  @doc """
  What the agent runs: `{front_end, back_end}` pipeline specs. The one
  callback every agent needs: nothing picks providers or models for it.
  `Octoroom.Agent.Pipeline.Spec.default/1` builds the usual stages from the
  ones you name; edit what it returns, or build both from stages of your own.

  Each input runs its own front end, and their turns go into the one back
  end. A `nil` front end makes the back end hear the inputs mixed, as
  `Spec.gemini_live/1` and `Spec.openai_live/1` do: one speech-to-speech
  model that takes its own turns, so `respond:` and `gate:` don't apply
  (see "Gemini Live and OpenAI Live" in `Octoroom.Agent.Worker`).
  """
  @callback pipeline(ctx) :: {Spec.t() | nil, Spec.t()}

  @doc """
  The questions for the decision model, as for `ReqLLM.evaluate/4` (with
  `gate: :decision`). Default: `default_questions/1`.
  """
  @callback questions(ctx) :: map

  @doc """
  Whether to answer a turn, from the decision model's answers (with
  `gate: :decision`). `turn` has `speaker`, `source`, `text` (nil for a
  half-cascaded turn), `named` (it says this agent's name) and `decision`,
  whose `answers` are the model's raw answers by question. `ctx` also has
  `thresholds`.

  `:wait` holds the turn for `wait_ms` and replies if nobody speaks. A bare
  outcome is reported with why `:decided`. Default: `decide/2`.
  """
  @callback decide(turn :: map, ctx) ::
              :reply | :wait | :listen | {:reply | :wait | :listen, why :: term}

  defmacro __using__(_opts) do
    quote do
      @behaviour Octoroom.Agent

      @impl Octoroom.Agent
      def instructions(_ctx), do: nil

      @impl Octoroom.Agent
      def tools(_ctx), do: []

      @impl Octoroom.Agent
      def initial_prompt(_ctx), do: nil

      @impl Octoroom.Agent
      def initial_say(_ctx), do: nil

      @impl Octoroom.Agent
      def questions(ctx), do: Octoroom.Agent.default_questions(ctx)

      @impl Octoroom.Agent
      def decide(turn, ctx), do: Octoroom.Agent.decide(turn, ctx)

      defoverridable instructions: 1,
                     tools: 1,
                     initial_prompt: 1,
                     initial_say: 1,
                     questions: 1,
                     decide: 2
    end
  end

  # Options passed through to `Octoroom.Agent.Worker` as they are.
  @worker_opts [
    :name,
    :description,
    :roster,
    :respond,
    :gate,
    :thresholds,
    :decisions,
    :follow_up_ms,
    :restore
  ]

  @doc """
  A worker spec for an agent, for a room's `workers/1`.

    * `hears:` (required) - the audio tracks it hears, usually
      `Enum.map(room.participants, &mic/1)`. People joining and leaving
      change it without restarting the agent.
    * `sees:` - optional video tracks it sees, such as
      `Enum.flat_map(room.participants, &[camera(&1), screen(&1)])`. Clients
      capture low-FPS JPEG snapshots of live, unmuted tracks and upload them
      through the room channel. Default `[]`.
    * `respond:` - `:always`, `:addressed` or `:never`: which turns start a
      reply. Default `:always` with one input, `:addressed` with more.
    * `name:` - what people call it, which `:addressed` listens for.
      Default: the id.
    * `description:` - what it's for ("answers questions about capital
      cities"), told to the decision model so it can tell agents apart.
    * `voice:` - `false` for an agent that listens and calls tools but
      never speaks (no text-to-speech, no output track: a data output
      named after the id instead, for its presence and transcript).
      Default `true`.
    * `restore:` - what to restore into the model's context if the agent
      restarts mid-call: `true` (default), `false`, or a keyword list of
      `history:`, `tool_results:`, `session:` (Gemini Live resumption handle),
      `notice:` (`true`, `false`/`nil`, or a custom reconnect string), and
      `prompt:` (cascaded only: `false` by default, `true` to automatically
      reply to the restored context, or a custom prompt string).
    * `args:` - passed to the callbacks as `ctx.args`. Changing it
      restarts the agent.
    * `gate:`, `thresholds:`, `decisions:`, `follow_up_ms:` - see
      `Octoroom.Agent.Worker`.

  It speaks on one output track named after the id. The room's default
  `subscriptions/2` includes worker outputs, so everyone hears it. Whoever
  is subscribed to that output (or, without a voice, its data output) sees
  the agent in their client: its presence (`name`, `description`, and a
  state of `listening`, `thinking`, `speaking` or `waiting`), its
  `transcript` events, and a `transcript_snapshot` when they subscribe.
  They may also type to it (`room.send(id, {text})` in the browser), if it
  hears them (see `Octoroom.Agent.Worker`).
  """
  def agent(id, module, opts) when is_binary(id) and is_atom(module) and is_list(opts) do
    {hears, opts} =
      case Keyword.pop(opts, :hears) do
        {nil, _} -> raise ArgumentError, "agent #{id}: hears: is required"
        found -> found
      end

    {sees, opts} = Keyword.pop(opts, :sees, [])
    {voice?, opts} = Keyword.pop(opts, :voice, true)
    {video_opt, opts} = Keyword.pop(opts, :video, false)
    {video_inputs, opts} = Keyword.pop(opts, :video_inputs, :client)
    {args, opts} = Keyword.pop(opts, :args, %{})

    case Keyword.keys(opts) -- @worker_opts do
      [] -> :ok
      unknown -> raise ArgumentError, "agent #{id}: unknown options #{inspect(unknown)}"
    end

    worker_args =
      opts
      |> Map.new()
      |> Map.put_new(:name, id)
      |> Map.merge(%{agent: module, args: args, voice: voice?})

    video_outputs =
      case video_opt do
        true ->
          [Octoroom.Track.video("#{id}/video")]

        name when is_binary(name) ->
          [Octoroom.Track.video(name)]

        false ->
          []

        nil ->
          []

        other ->
          raise ArgumentError,
                "agent #{id}: video: must be a boolean or track name, got #{inspect(other)}"
      end

    audio_outputs = if voice?, do: [id], else: []

    Octoroom.Room.worker(id, Octoroom.Agent.Worker,
      inputs: hears ++ sees,
      video_inputs: video_inputs,
      outputs: audio_outputs ++ video_outputs,
      data: if(voice? or video_outputs != [], do: [], else: [id]),
      args: worker_args
    )
  end

  @doc """
  Worker specs for several agents in one room, each `{id, module, opts}`
  as for `agent/3`, with `shared` options merged under each agent's own:

      agents(
        [
          {"assistant", MyApp.Assistant, name: "Assistant"},
          {"atlas", MyApp.Atlas, name: "Atlas", description: "Answers questions about capital cities."}
        ],
        hears: Enum.map(room.participants, &mic/1),
        gate: :decision
      )

  Each agent gets the roster (`ctx.roster`: `id`, `name` and `description`
  of every agent), so the decision model is asked which of them a turn is
  for, and whether each could answer it. Each agent still makes its own
  decision call per turn.

  A turn that says another agent's name, and not this one's, isn't a
  follow-up for this one.
  """
  def agents(specs, shared \\ []) when is_list(specs) and is_list(shared) do
    roster =
      for {id, _module, opts} <- specs do
        opts = Keyword.merge(shared, opts)
        %{id: id, name: Keyword.get(opts, :name, id), description: opts[:description]}
      end

    for {id, module, opts} <- specs,
        do: agent(id, module, shared |> Keyword.merge(opts) |> Keyword.put(:roster, roster))
  end

  # -- The decision gate's defaults

  @doc """
  The decision model's default questions for an agent: `"addressee"`, a
  choice of who the speaker is talking to (each agent in `ctx.roster` by
  id, `"person"`, `"group"` or `"nobody"`), and whether the agent could
  answer: `"answerable"` when it's the only agent, or
  `"answerable_<key>"` for each agent when there are several, where `key`
  is `question_key/1` of its id (the API takes only `[A-Za-z0-9_-]` in
  question and choice names).
  """
  def default_questions(ctx) do
    roster = roster(ctx)
    names = Enum.map_join(roster, ", ", & &1.name)

    agents =
      Map.new(roster, fn a ->
        {question_key(a.id), "#{a.name}, an AI assistant in the call.#{about(a)}"}
      end)

    addressee = %{
      type: :choice,
      instructions:
        "This is one turn from a group voice call that includes " <>
          if(length(roster) == 1,
            do: "an AI assistant, #{names}. ",
            else: "AI assistants: #{names}. "
          ) <>
          "Who is the speaker talking to?",
      criteria:
        Map.merge(agents, %{
          "person" => "A specific other person in the call.",
          "group" => "Everyone in the call, or no one in particular.",
          "nobody" => "Nobody: thinking aloud, a remark, or a statement."
        })
    }

    answerable =
      case roster do
        [a] ->
          %{"answerable" => answerable_question(a)}

        many ->
          Map.new(many, &{"answerable_#{question_key(&1.id)}", answerable_question(&1)})
      end

    Map.put(answerable, "addressee", addressee)
  end

  defp answerable_question(agent) do
    %{
      type: :boolean,
      instructions:
        "Is this a question or request that #{agent.name}, an AI assistant, " <>
          "should answer right now?#{about(agent)}"
    }
  end

  defp about(%{description: d}) when is_binary(d) and d != "", do: " " <> d
  defp about(_agent), do: ""

  @doc """
  The default decision: reply when the turn says the agent's name, and
  otherwise, with `ctx.thresholds` (see `Octoroom.Agent.Worker`),

    * reply when the model gives this agent at least `reply_above`;
    * wait from `wait_above`, if no other agent is more likely;
    * wait on an open question (to the group or nobody) that this agent is
      at least `answer_above` likely to answer, and no other agent more so;
    * otherwise listen.
  """
  def decide(%{named: true}, _ctx), do: {:reply, :name}

  def decide(%{decision: d}, ctx) do
    t = ctx.thresholds
    me = ctx.agent_id
    roster = roster(ctx)
    probabilities = d[:probabilities] || %{}
    # A single agent's choice may be the old "assistant", whatever its id.
    assistant =
      probabilities[question_key(me)] || (length(roster) == 1 && probabilities["assistant"]) ||
        0.0

    answerable = answerable(d, me, roster)

    others = for a <- roster, a.id != me, do: a.id
    likeliest? = Enum.all?(others, &((probabilities[question_key(&1)] || 0.0) <= assistant))
    best_placed? = Enum.all?(others, &(answerable(d, &1, roster) <= answerable))

    cond do
      assistant >= t.reply_above ->
        {:reply, :addressed}

      assistant >= t.wait_above and likeliest? ->
        {:wait, :maybe_addressed}

      d[:addressee] in ["group", "nobody"] and answerable >= t.answer_above and best_placed? ->
        {:wait, :open_question}

      true ->
        {:listen, :not_addressed}
    end
  end

  defp answerable(d, id, roster) do
    answers = d[:answers] || %{}

    case get_in(answers, ["answerable_#{question_key(id)}", "probability"]) do
      p when is_number(p) -> p
      _ when length(roster) <= 1 -> d[:answerable] || 0.0
      _ -> 0.0
    end
  end

  @doc """
  An agent id as the decision model's questions and choices name it: up to
  64 of `[A-Za-z0-9_-]`, anything else becoming `_`.
  """
  def question_key(id), do: id |> String.replace(~r/[^A-Za-z0-9_-]/, "_") |> String.slice(0, 50)

  defp roster(%{roster: [_ | _] = roster}), do: roster

  defp roster(ctx),
    do: [%{id: ctx.agent_id, name: Map.get(ctx, :name, ctx.agent_id), description: nil}]

  @doc """
  Speaks `text` now, word for word, interrupting whatever the agent is
  saying. It goes into the conversation as the agent's own words. Returns
  `:ok`, or `{:error, :no_worker}`.
  """
  def say(room_id, agent_id, text) when is_binary(text),
    do: Octoroom.Worker.send(room_id, agent_id, {:octoroom_agent, :say, text})

  @doc """
  Starts a reply to `text`, an instruction from the app that the model
  sees as not said by anyone on the call ("Summarize the last five
  minutes"). Returns `:ok`, or `{:error, :no_worker}`.
  """
  def prompt(room_id, agent_id, text) when is_binary(text),
    do: Octoroom.Worker.send(room_id, agent_id, {:octoroom_agent, :prompt, text})

  @doc "Stops what the agent is saying. Returns `:ok`, or `{:error, :no_worker}`."
  def interrupt(room_id, agent_id),
    do: Octoroom.Worker.send(room_id, agent_id, {:octoroom_agent, :interrupt})

  @doc """
  The agent's conversation so far: its `{:conversation, item}` events'
  items, the latest version of each, oldest first, each with `at` (unix ms,
  when it was first seen). Up to the last 200.

  The agent saves it with its history (`Octoroom.Worker`'s `save:`), so
  it's there while the room is down and after the agent restarts, which
  then carries on the conversation. For an app that rebuilds a transcript
  when it mounts. A reply that was playing when the agent stopped comes
  back `"interrupted"`.
  """
  def conversation(room_id, agent_id) do
    case Octoroom.Worker.saved(room_id, agent_id) do
      %{items: items} -> items
      _ -> []
    end
  end
end
