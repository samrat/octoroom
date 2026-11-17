defmodule Octoroom.Agent.Pipeline.Test do
  @moduledoc """
  Runs a pipeline spec in the calling process, with no sockets or
  timers, for tests.

      import Octoroom.Agent.Pipeline.Spec
      alias Octoroom.Agent.Pipeline.Test

      harness =
        processor(MyApp.IgnoreBackchannel)
        |> Test.start!()
        |> Test.push([%Frames.VADUserStartedSpeaking{}, %Frames.InterimTranscription{text: "uh-huh"}])

      refute Test.interrupted?(harness)

  Async work runs according to `:async`:

    * `:inline` (default) - each task runs to completion in the calling
      process as soon as the frame that started it is handled. Its emitted
      messages are delivered in order, then its result.
    * `:manual` - tasks wait until `run_tasks/1` or `run_task/3`, so a test
      can interrupt while work is in flight.

  Timers never fire by themselves; use `fire_timer/3`.
  """

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Core
  alias Octoroom.Agent.Pipeline.Spec

  defstruct core: nil,
            async: :inline,
            outputs: [],
            upstream: [],
            observed: [],
            notifications: [],
            errors: [],
            interruptions: 0,
            tasks: [],
            timers: %{}

  @type t :: %__MODULE__{}

  @doc "Starts a harness for `spec`. Options: `:async` (`:inline` or `:manual`), `:ctx`."
  def start(%Spec{} = spec, opts \\ []) do
    async = Keyword.get(opts, :async, :inline)

    unless async in [:inline, :manual] do
      raise ArgumentError, "async must be :inline or :manual, got: #{inspect(async)}"
    end

    with {:ok, core} <- Core.new(spec, Keyword.get(opts, :ctx, %{})) do
      {:ok, %__MODULE__{core: core, async: async}}
    end
  end

  @doc "Like `start/2`, but raises on error."
  def start!(spec, opts \\ []) do
    case start(spec, opts) do
      {:ok, harness} -> harness
      {:error, reason} -> raise ArgumentError, "pipeline failed to start: #{inspect(reason)}"
    end
  end

  @doc "Starts a harness and pushes `frames` downstream. Takes `start/2`'s options."
  def run(%Spec{} = spec, frames, opts \\ []), do: spec |> start!(opts) |> push(frames)

  @doc "Pushes a frame (or a list of frames) into the pipeline."
  def push(harness, frames, direction \\ :downstream)

  def push(%__MODULE__{} = harness, frames, direction) when is_list(frames),
    do: Enum.reduce(frames, harness, &push(&2, &1, direction))

  def push(%__MODULE__{} = harness, frame, direction) do
    {commands, core} = Core.push(harness.core, frame, direction)
    apply_commands(%{harness | core: core}, commands)
  end

  @doc "Delivers a `handle_info/2` message to stage `name`."
  def info(%__MODULE__{} = harness, name, message) do
    {commands, core} = Core.info(harness.core, name, message)
    apply_commands(%{harness | core: core}, commands)
  end

  @doc "Fires the pending timer `key` of stage `name`."
  def fire_timer(%__MODULE__{} = harness, name, key) do
    index =
      Core.stage_index(harness.core, name) || raise ArgumentError, "no stage #{inspect(name)}"

    case Enum.find(Map.keys(harness.timers), &match?({^index, ^key, _}, &1)) do
      nil ->
        raise ArgumentError, "no pending timer #{inspect(key)} on #{inspect(name)}"

      id ->
        harness = %{harness | timers: Map.delete(harness.timers, id)}
        {commands, core} = Core.timer_fired(harness.core, id)
        apply_commands(%{harness | core: core}, commands)
    end
  end

  @doc "True if stage `name` has a pending timer `key`."
  def timer_pending?(%__MODULE__{} = harness, name, key) do
    index = Core.stage_index(harness.core, name)
    Enum.any?(Map.keys(harness.timers), &match?({^index, ^key, _}, &1))
  end

  @doc "Keys of the tasks waiting to run (`:manual` mode), as `{stage_name, key}`."
  def pending_tasks(%__MODULE__{} = harness) do
    names = harness.core.index |> Map.new(fn {name, index} -> {index, name} end)
    Enum.map(harness.tasks, fn {{index, key, _n}, _fun} -> {Map.fetch!(names, index), key} end)
  end

  @doc "Runs every waiting task, including ones started by those tasks' results."
  def run_tasks(%__MODULE__{tasks: []} = harness), do: harness

  def run_tasks(%__MODULE__{tasks: [{id, fun} | rest]} = harness) do
    %{harness | tasks: rest} |> execute(id, fun) |> run_tasks()
  end

  @doc "Runs the waiting task `key` of stage `name`."
  def run_task(%__MODULE__{} = harness, name, key) do
    index = Core.stage_index(harness.core, name)

    case Enum.split_with(harness.tasks, &match?({{^index, ^key, _}, _}, &1)) do
      {[{id, fun}], rest} -> execute(%{harness | tasks: rest}, id, fun)
      {[], _} -> raise ArgumentError, "no waiting task #{inspect(key)} on #{inspect(name)}"
    end
  end

  @doc "Frames that left the last stage, oldest first, optionally only of `module`."
  def outputs(%__MODULE__{outputs: outputs}, module \\ nil) do
    frames = Enum.reverse(outputs)
    if module, do: Enum.filter(frames, &is_struct(&1, module)), else: frames
  end

  @doc "True if a frame of `module` left the last stage."
  def received?(%__MODULE__{} = harness, module), do: outputs(harness, module) != []

  @doc "Frames (other than errors) that left the first stage upstream, oldest first."
  def upstream(%__MODULE__{upstream: frames}), do: Enum.reverse(frames)

  @doc "Events sent with `{:notify, event}`, oldest first."
  def notifications(%__MODULE__{notifications: notifications}), do: Enum.reverse(notifications)

  @doc "`{reason, fatal?}` for each error that left the first stage, oldest first."
  def errors(%__MODULE__{errors: errors}), do: Enum.reverse(errors)

  @doc "True if anything interrupted the pipeline."
  def interrupted?(%__MODULE__{interruptions: n}), do: n > 0

  @doc "The state of stage `name`."
  def state(%__MODULE__{core: core}, name), do: Core.stage_state(core, name)

  # -- Commands --

  defp apply_commands(harness, commands) do
    harness = Enum.reduce(commands, harness, &apply_command(&2, &1))

    if harness.async == :inline, do: run_tasks(harness), else: harness
  end

  defp apply_command(harness, {:output, frame}),
    do: %{harness | outputs: [frame | harness.outputs]}

  defp apply_command(harness, {:notify, event}),
    do: %{harness | notifications: [event | harness.notifications]}

  defp apply_command(harness, {:output_upstream, %Frames.Error{} = error}),
    do: %{harness | errors: [{error.reason, error.fatal?} | harness.errors]}

  defp apply_command(harness, {:output_upstream, frame}),
    do: %{harness | upstream: [frame | harness.upstream]}

  defp apply_command(harness, {:observe, frame}),
    do: %{harness | observed: [frame | harness.observed]}

  defp apply_command(harness, {:interrupted, _generation}),
    do: %{harness | interruptions: harness.interruptions + 1}

  defp apply_command(harness, {:start_task, id, fun}),
    do: %{harness | tasks: harness.tasks ++ [{id, fun}]}

  defp apply_command(harness, {:kill_task, id}),
    do: %{harness | tasks: Enum.reject(harness.tasks, &match?({^id, _}, &1))}

  defp apply_command(harness, {:start_timer, id, ms}),
    do: %{harness | timers: Map.put(harness.timers, id, ms)}

  defp apply_command(harness, {:cancel_timer, id}),
    do: %{harness | timers: Map.delete(harness.timers, id)}

  # Runs the task in this process. Emitted messages go through the mailbox
  # under a unique ref, so a selective receive collects them in order.
  defp execute(harness, id, fun) do
    ref = make_ref()
    parent = self()

    result =
      try do
        {:done, fun.(fn message -> send(parent, {ref, message}) && :ok end)}
      rescue
        error -> {:failed, error}
      catch
        kind, reason -> {:failed, {kind, reason}}
      end

    emitted = collect(ref, [])

    Enum.reduce(emitted ++ [result], harness, fn message, harness ->
      {commands, core} = Core.async_message(harness.core, id, message)
      harness = %{harness | core: core}
      Enum.reduce(commands, harness, &apply_command(&2, &1))
    end)
  end

  defp collect(ref, acc) do
    receive do
      {^ref, message} -> collect(ref, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
