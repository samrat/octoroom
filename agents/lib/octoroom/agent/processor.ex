defmodule Octoroom.Agent.Processor do
  @moduledoc """
  A stage in a pipeline. See docs/pipelines.md.

  Processors don't send messages or start processes for their work. Every
  callback returns a list of effects, and the runner executes them in order:

    * `{:push, frame, :downstream | :upstream}` - send a frame to the next or
      previous stage
    * `{:async, key, fun}` - run `fun.(emit)` in a task owned by the runner.
      Each `emit.(message)` arrives as `handle_async(key, message, state)`;
      the return value arrives as `{:done, result}` and a crash as
      `{:failed, reason}`, so emitted messages must not have those shapes
      (wrap them). Starting a key that is running replaces the old
      task. An interruption kills the task, unless it was started while
      handling an uninterruptible frame.
    * `{:cancel, key}` - kill a running task
    * `{:timer, key, ms}` / `{:cancel_timer, key}` - `handle_timer(key, state)`
      after `ms`. Interruptions don't cancel timers.
    * `{:notify, event}` - send `event` to the session owner
    * `{:error, reason, fatal?}` - push a `Octoroom.Agent.Frames.Error` upstream

  `use Octoroom.Agent.Processor` defines every callback: frames pass through
  unchanged and other messages are ignored, so a processor only needs to
  match what it cares about.

      defmodule MyApp.Shout do
        use Octoroom.Agent.Processor

        @impl true
        def handle_frame(%Octoroom.Agent.Frames.LLMText{} = frame, :downstream, state) do
          {[{:push, %{frame | text: String.upcase(frame.text)}, :downstream}], state}
        end

        def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}
      end
  """

  @type direction :: :downstream | :upstream
  @type state :: term()
  @type effect ::
          {:push, struct(), direction()}
          | {:async, key :: term(), (emit :: (term() -> :ok) -> term())}
          | {:cancel, key :: term()}
          | {:timer, key :: term(), ms :: non_neg_integer()}
          | {:cancel_timer, key :: term()}
          | {:notify, event :: term()}
          | {:error, reason :: term(), fatal? :: boolean()}

  @typedoc """
  Given to `init/2`: the stage's `:name` and `:index`, `:reply_to` when the
  runner runs in a process (see `send_to/2`), plus whatever the runner adds.
  """
  @type ctx :: map()

  @callback init(opts :: keyword(), ctx()) :: {:ok, state()} | {:error, term()}
  @callback handle_frame(frame :: struct(), direction(), state()) :: {[effect()], state()}
  @callback handle_async(key :: term(), message :: term(), state()) :: {[effect()], state()}
  @callback handle_timer(key :: term(), state()) :: {[effect()], state()}
  @callback handle_info(message :: term(), state()) :: {[effect()], state()}
  @callback terminate(reason :: term(), state()) :: term()

  defmacro __using__(_opts) do
    quote do
      @behaviour Octoroom.Agent.Processor

      @impl true
      def init(opts, _ctx), do: {:ok, Map.new(opts)}

      @impl true
      def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

      @impl true
      def handle_async(_key, _message, state), do: {[], state}

      @impl true
      def handle_timer(_key, state), do: {[], state}

      @impl true
      def handle_info(_message, state), do: {[], state}

      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable init: 2,
                     handle_frame: 3,
                     handle_async: 3,
                     handle_timer: 2,
                     handle_info: 2,
                     terminate: 2
    end
  end

  @doc """
  Initializes `module`, whether it is a plain processor or a
  `Octoroom.Agent.Processor.StateMachine`.
  """
  def init(module, opts, ctx) do
    if function_exported?(module, :__state_machine__, 0),
      do: Octoroom.Agent.Processor.StateMachine.init(module, opts, ctx),
      else: module.init(opts, ctx)
  end

  @doc """
  Sends `message` from another process (a socket, for example) to the
  processor whose `ctx.reply_to` this is. It arrives as `handle_info/2`.
  """
  def send_to({runner, name}, message) when is_pid(runner) do
    send(runner, {:octoroom_agent_processor_info, name, message})
    :ok
  end
end
