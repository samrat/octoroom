defmodule Octoroom.Agent.Processor.StateMachine do
  @moduledoc """
  A processor written as a state machine, with `gen_statem` semantics.

      defmodule MyApp.Turns do
        use Octoroom.Agent.Processor.StateMachine

        @impl true
        def init(_opts, _ctx), do: {:ok, :idle, %{}}

        @impl true
        def handle_event(%Frames.VADUserStoppedSpeaking{}, :speaking, data),
          do: {:next_state, :paused, data, [{:state_timeout, 2_000, :silence}]}

        def handle_event({:state_timeout, :silence}, :paused, data),
          do: {:next_state, :idle, data, [{:push, %Frames.UserStoppedSpeaking{}, :downstream}]}
      end

  Events:

    * a frame moving downstream, as the frame itself
    * `{:upstream, frame}` for a frame moving upstream
    * `{:async, key, message}` for task messages
    * `{:timer, key}` for timers started with `{:timer, key, ms}`
    * `{:state_timeout, key}` for state timeouts
    * `{:info, message}` for other messages

  Results: `{:next_state, name, data}`, `{:next_state, name, data, actions}`,
  `{:keep_state, data}`, `{:keep_state, data, actions}`,
  `:keep_state_and_data` or `{:keep_state_and_data, actions}`.

  Actions are processor effects (see `Octoroom.Agent.Processor`) plus:

    * `{:state_timeout, ms, key}` - fires `{:state_timeout, key}` unless the
      state changes first
    * `:postpone` - hold the current event and deliver it again after the next
      state change

  On a state change, the optional `state_enter(old_state, new_state, data)`
  runs and returns `{:keep_state, data, actions}` (or `:keep_state_and_data`),
  then postponed events are delivered again in order.

  Frames and other events that no `handle_event/3` clause matches pass through
  (frames) or are ignored (everything else).
  """

  @callback init(opts :: keyword(), ctx :: map()) ::
              {:ok, state_name :: term(), data :: term()} | {:error, term()}
  @callback handle_event(event :: term(), state_name :: term(), data :: term()) :: term()
  @callback state_enter(old :: term(), new :: term(), data :: term()) :: term()

  @optional_callbacks state_enter: 3

  @state_timeout :__state_timeout__

  defmacro __using__(_opts) do
    quote do
      @behaviour Octoroom.Agent.Processor.StateMachine
      @before_compile Octoroom.Agent.Processor.StateMachine

      alias Octoroom.Agent.Frames

      @doc false
      def __state_machine__, do: true
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      # Fallbacks, after the module's own clauses: frames pass through.
      def handle_event({:upstream, frame}, _state_name, _data) when is_struct(frame),
        do: {:keep_state_and_data, [{:push, frame, :upstream}]}

      def handle_event(frame, _state_name, _data) when is_struct(frame),
        do: {:keep_state_and_data, [{:push, frame, :downstream}]}

      def handle_event(_event, _state_name, _data), do: :keep_state_and_data

      # The `Octoroom.Agent.Processor` callbacks. (`init/2` is the state machine's;
      # `Octoroom.Agent.Processor.init/3` adapts it.)
      def handle_frame(frame, direction, state),
        do: Octoroom.Agent.Processor.StateMachine.frame(__MODULE__, frame, direction, state)

      def handle_async(key, message, state),
        do: Octoroom.Agent.Processor.StateMachine.event(__MODULE__, {:async, key, message}, state)

      def handle_timer(key, state),
        do: Octoroom.Agent.Processor.StateMachine.timer(__MODULE__, key, state)

      def handle_info(message, state),
        do: Octoroom.Agent.Processor.StateMachine.event(__MODULE__, {:info, message}, state)

      def terminate(_reason, _state), do: :ok
    end
  end

  @doc false
  def init(module, opts, ctx) do
    case module.init(opts, ctx) do
      {:ok, name, data} -> {:ok, %{name: name, data: data, postponed: [], timeout_key: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def frame(module, frame, :downstream, state), do: event(module, frame, state)
  def frame(module, frame, :upstream, state), do: event(module, {:upstream, frame}, state)

  @doc false
  def timer(module, @state_timeout, %{timeout_key: key} = state),
    do: event(module, {:state_timeout, key}, %{state | timeout_key: nil})

  def timer(module, key, state), do: event(module, {:timer, key}, state)

  @doc false
  def event(module, event, state) do
    {name, data, actions} = normalize(module.handle_event(event, state.name, state.data), state)

    # A state change cancels the old state timeout before the new actions run.
    {cancel, state} =
      if name != state.name and state.timeout_key != nil,
        do: {[{:cancel_timer, @state_timeout}], %{state | timeout_key: nil}},
        else: {[], state}

    {effects, state} = apply_actions(actions, event, %{state | data: data})
    effects = cancel ++ effects

    if name != state.name do
      enter(module, state.name, name, effects, state)
    else
      {effects, state}
    end
  end

  defp enter(module, old, new, effects, state) do
    state = %{state | name: new}

    {effects, state} =
      if function_exported?(module, :state_enter, 3) do
        case module.state_enter(old, new, state.data) do
          :keep_state_and_data ->
            {effects, state}

          {:keep_state, data} ->
            {effects, %{state | data: data}}

          {:keep_state, data, actions} ->
            {more, state} = apply_actions(actions, nil, %{state | data: data})
            {effects ++ more, state}
        end
      else
        {effects, state}
      end

    # Postponed events run again, in order.
    {postponed, state} = {state.postponed, %{state | postponed: []}}

    Enum.reduce(postponed, {effects, state}, fn event, {effects, state} ->
      {more, state} = event(module, event, state)
      {effects ++ more, state}
    end)
  end

  defp normalize({:next_state, name, data}, _state), do: {name, data, []}
  defp normalize({:next_state, name, data, actions}, _state), do: {name, data, actions}
  defp normalize({:keep_state, data}, state), do: {state.name, data, []}
  defp normalize({:keep_state, data, actions}, state), do: {state.name, data, actions}
  defp normalize(:keep_state_and_data, state), do: {state.name, state.data, []}
  defp normalize({:keep_state_and_data, actions}, state), do: {state.name, state.data, actions}

  defp normalize(other, _state),
    do: raise(ArgumentError, "invalid state machine result: #{inspect(other)}")

  defp apply_actions(actions, event, state) do
    Enum.reduce(actions, {[], state}, fn
      :postpone, {effects, state} when event != nil ->
        {effects, %{state | postponed: state.postponed ++ [event]}}

      {:state_timeout, ms, key}, {effects, state} ->
        {effects ++ [{:timer, @state_timeout, ms}], %{state | timeout_key: key}}

      effect, {effects, state} ->
        {effects ++ [effect], state}
    end)
  end
end
