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

  Every callback gets `ctx`: `room_id`, `agent_id`, `participants` (when
  the agent started), `resumed` (see `Octoroom.Worker.Context`) and `args`
  (from `agent/3`). All callbacks are optional.

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
  The providers: an `Octoroom.Agent.Backend.Cascaded` struct, or a map for
  `Octoroom.Agent.Backend.Cascaded.new/1`. Default `%{}`: Soniox, Gemini
  through ReqLLM, Inworld.
  """
  @callback backend(ctx) :: %Octoroom.Agent.Backend.Cascaded{} | map

  @doc """
  Something to answer as soon as the agent starts, as if a person had said
  it ("Greet the visitor"). Not used when the agent restarts during a room's
  recovery (`ctx.resumed`), so it doesn't greet twice.
  """
  @callback initial_text(ctx) :: String.t() | nil

  @doc """
  `{front_end, back_end}` pipeline specs to run instead of the backend's
  (see `Octoroom.Agent.Pipeline.Spec.cascaded_split/2`), for custom stages
  or fake providers in tests. `nil` uses the backend's.
  """
  @callback pipeline(ctx) :: {Spec.t(), Spec.t()} | nil

  defmacro __using__(_opts) do
    quote do
      @behaviour Octoroom.Agent

      @impl Octoroom.Agent
      def instructions(_ctx), do: nil

      @impl Octoroom.Agent
      def tools(_ctx), do: []

      @impl Octoroom.Agent
      def backend(_ctx), do: %{}

      @impl Octoroom.Agent
      def initial_text(_ctx), do: nil

      @impl Octoroom.Agent
      def pipeline(_ctx), do: nil

      defoverridable instructions: 1, tools: 1, backend: 1, initial_text: 1, pipeline: 1
    end
  end

  # Options passed through to `Octoroom.Agent.Worker` as they are.
  @worker_opts [:name, :respond, :gate, :thresholds, :decisions, :follow_up_ms]

  @doc """
  A worker spec for an agent, for a room's `workers/1`.

    * `hears:` (required) - the audio tracks it hears, usually
      `Enum.map(room.participants, &mic/1)`. People joining and leaving
      change it without restarting the agent.
    * `respond:` - `:always`, `:addressed` or `:never`: which turns start a
      reply. Default `:always` with one input, `:addressed` with more.
    * `name:` - what people call it, which `:addressed` listens for.
      Default: the id.
    * `voice:` - `false` for an agent that listens and calls tools but
      never speaks (no text-to-speech, no output track). Default `true`.
    * `args:` - passed to the callbacks as `ctx.args`. Changing it
      restarts the agent.
    * `gate:`, `thresholds:`, `decisions:`, `follow_up_ms:` - see
      `Octoroom.Agent.Worker`.

  It speaks on one output track named after the id. The room's default
  `subscriptions/2` includes worker outputs, so everyone hears it.
  """
  def agent(id, module, opts) when is_binary(id) and is_atom(module) and is_list(opts) do
    {hears, opts} =
      case Keyword.pop(opts, :hears) do
        {nil, _} -> raise ArgumentError, "agent #{id}: hears: is required"
        found -> found
      end

    {voice?, opts} = Keyword.pop(opts, :voice, true)
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

    Octoroom.Room.worker(id, Octoroom.Agent.Worker,
      inputs: hears,
      outputs: if(voice?, do: [id], else: []),
      args: worker_args
    )
  end

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
end
