defmodule Octoroom.Agent.Pipeline.Core do
  @moduledoc """
  The pure part of an agent's pipeline.

  The core holds the processors, delivers frames between them, and executes
  their effects. It starts no processes and sends no messages. Each call
  returns a list of commands for its host to carry out, and the host feeds
  task results, timer expiries and messages back in. Hosts are the room
  worker (`Octoroom.Agent.Worker`) and the test harness
  (`Octoroom.Agent.Pipeline.Test`).

  Commands:

    * `{:output, frame}` - a frame left the last stage downstream
    * `{:output_upstream, frame}` - a frame left the first stage upstream
      (an `Error` frame there should end the call)
    * `{:start_task, id, fun}` - run `fun.(emit)`; report each emitted
      message and then `{:done, result}` (or `{:failed, reason}`) with
      `async_message/3`
    * `{:kill_task, id}` - kill that task; anything it still reports is
      dropped
    * `{:start_timer, id, ms}` / `{:cancel_timer, id}` - call `timer_fired/2`
      after `ms`
    * `{:notify, event}` - send `event` to the session owner
    * `{:interrupted, generation}` - an interruption happened; reset playback
    * `{:observe, frame}` - a frame of an observed type was pushed (see
      `observe/2`)

  An `Octoroom.Agent.Frames.UpdateStage` frame goes to the `handle_update/2`
  of the stage it names, not its `handle_frame/3`, and goes no further. A
  stage without `handle_update/2` reports an error instead. One that names
  no stage here leaves the pipeline like any other frame.

  Task and timer ids are opaque. The core drops reports for ids it no longer
  knows, so the host doesn't have to track generations.
  """

  require Logger

  alias Octoroom.Agent.Frame
  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Spec

  # Audio frames are too frequent for per-frame telemetry.
  @untraced [Frames.InputAudio, Frames.OutputAudio]

  defstruct stages: {},
            index: %{},
            system: :queue.new(),
            queue: :queue.new(),
            generation: 0,
            seq: 0,
            tasks: %{},
            timers: %{},
            current: nil,
            interrupting?: false,
            observed: MapSet.new(),
            telemetry: %{},
            commands: []

  @type t :: %__MODULE__{}
  @type command ::
          {:output, struct()}
          | {:output_upstream, struct()}
          | {:start_task, term(), function()}
          | {:kill_task, term()}
          | {:start_timer, term(), non_neg_integer()}
          | {:cancel_timer, term()}
          | {:notify, term()}
          | {:interrupted, non_neg_integer()}
          | {:observe, struct()}

  @doc """
  Validates the spec and initializes every processor. `ctx` is merged into
  each processor's `init/2` context; pass `runner: pid` to give processors a
  `:reply_to` for `Octoroom.Agent.Processor.send_to/2`. `ctx[:telemetry]` is added
  to telemetry metadata (the runner puts the session id there).
  """
  @spec new(Spec.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(%Spec{} = spec, ctx \\ %{}) do
    with {:ok, spec} <- Spec.validate(spec),
         {:ok, stages} <- init_stages(spec.stages, ctx) do
      index = stages |> Enum.with_index() |> Map.new(fn {stage, i} -> {stage.name, i} end)

      core = %__MODULE__{
        stages: List.to_tuple(stages),
        index: index,
        telemetry: Map.get(ctx, :telemetry, %{})
      }

      :telemetry.execute(
        [:octoroom_agent, :pipeline, :init],
        %{stages: length(stages)},
        base_meta(core, %{stages: Enum.map(stages, & &1.name)})
      )

      {:ok, core}
    end
  end

  defp init_stages(stages, ctx) do
    stages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {%Spec.Stage{} = stage, index}, {:ok, acc} ->
      %Spec.Stage{module: module, opts: opts} = Spec.Stage.resolve(stage)
      stage_ctx = Map.merge(ctx, %{name: stage.name, index: index})

      stage_ctx =
        case ctx do
          %{runner: runner} when is_pid(runner) ->
            Map.put(stage_ctx, :reply_to, {runner, Map.get(ctx, :path, []) ++ [stage.name]})

          _ctx ->
            stage_ctx
        end

      case init_stage(module, opts, stage_ctx) do
        {:ok, state} ->
          {:cont, {:ok, [%{name: stage.name, module: module, state: state} | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:init_failed, stage.name, reason}}}
      end
    end)
    |> case do
      {:ok, stages} -> {:ok, Enum.reverse(stages)}
      error -> error
    end
  end

  defp init_stage(module, opts, ctx) do
    Code.ensure_loaded(module)
    Octoroom.Agent.Processor.init(module, opts, ctx)
  rescue
    error -> {:error, error}
  end

  @doc "Pushes a frame into the first stage (downstream) or the last (upstream)."
  @spec push(t(), struct(), :downstream | :upstream) :: {[command()], t()}
  def push(%__MODULE__{} = core, frame, direction \\ :downstream) do
    run(core, fn core ->
      case direction do
        :downstream -> route(core, -1, frame, :downstream)
        :upstream -> route(core, tuple_size(core.stages), frame, :upstream)
      end
    end)
  end

  @doc "Reports a message from a task started with `{:start_task, id, fun}`."
  @spec async_message(t(), term(), term()) :: {[command()], t()}
  def async_message(%__MODULE__{} = core, {index, key, _n} = id, message) do
    case Map.get(core.tasks, {index, key}) do
      %{id: ^id} = task ->
        run(core, fn core ->
          case message do
            {:done, result} ->
              core = %{core | tasks: Map.delete(core.tasks, {index, key})}
              async_stop(task, done_status(result))
              call(core, index, :handle_async, [key, message])

            {:failed, reason} ->
              core = %{core | tasks: Map.delete(core.tasks, {index, key})}
              async_exception(task, reason)
              call(core, index, :handle_async, [key, message])

            _streaming ->
              on_effects = &record_async_output(&1, {index, key}, id, &2)
              call(core, index, :handle_async, [key, message], on_effects)
          end
        end)

      _unknown ->
        {[], core}
    end
  end

  def async_message(%__MODULE__{} = core, _id, _message), do: {[], core}

  @doc "Reports that a timer started with `{:start_timer, id, ms}` fired."
  @spec timer_fired(t(), term()) :: {[command()], t()}
  def timer_fired(%__MODULE__{} = core, {index, key, _n} = id) do
    case Map.get(core.timers, {index, key}) do
      ^id ->
        run(core, fn core ->
          core = %{core | timers: Map.delete(core.timers, {index, key})}
          call(core, index, :handle_timer, [key])
        end)

      _unknown ->
        {[], core}
    end
  end

  def timer_fired(%__MODULE__{} = core, _id), do: {[], core}

  @doc """
  Delivers a message to `handle_info/2`.

  `target` is a stage name, a path of stage names into composite stages
  (as in `ctx.reply_to`), or `:broadcast` for every stage. Broadcast is for
  messages from processes that can't address one stage, such as STT sockets
  started with the runner as their parent.
  """
  @spec info(t(), atom() | [atom()] | :broadcast, term()) :: {[command()], t()}
  def info(%__MODULE__{} = core, :broadcast, message) do
    run(core, fn core ->
      Enum.reduce(0..(tuple_size(core.stages) - 1)//1, core, fn index, core ->
        call(core, index, :handle_info, [message])
      end)
    end)
  end

  def info(%__MODULE__{} = core, [name], message), do: info(core, name, message)

  # A path into a composite: the composite unwraps the rest.
  def info(%__MODULE__{} = core, [name | rest], message),
    do: info(core, name, {:octoroom_agent_path, rest, message})

  def info(%__MODULE__{} = core, name, message) do
    case Map.fetch(core.index, name) do
      {:ok, index} -> run(core, &call(&1, index, :handle_info, [message]))
      :error -> {[], core}
    end
  end

  @doc "Emits `{:observe, frame}` whenever a frame of one of `modules` is pushed."
  @spec observe(t(), Enumerable.t()) :: t()
  def observe(%__MODULE__{} = core, modules), do: %{core | observed: MapSet.new(modules)}

  @doc "Sets a key in the telemetry metadata carried on every event emitted by this core."
  @spec put_telemetry(t(), atom(), term()) :: t()
  def put_telemetry(%__MODULE__{} = core, key, value),
    do: %{core | telemetry: Map.put(core.telemetry, key, value)}

  @doc "Calls every processor's `terminate/2` and returns the cleanup commands."
  @spec terminate(t(), term()) :: [command()]
  def terminate(%__MODULE__{} = core, reason) do
    for stage <- Tuple.to_list(core.stages) do
      try do
        stage.module.terminate(reason, stage.state)
      rescue
        error -> Logger.warning("#{inspect(stage.name)} terminate failed: #{inspect(error)}")
      end
    end

    for {_key, task} <- core.tasks, do: async_stop(task, {:terminated, reason})

    Enum.map(core.tasks, fn {_key, task} -> {:kill_task, task.id} end) ++
      Enum.map(core.timers, fn {_key, id} -> {:cancel_timer, id} end)
  end

  @doc "The index of stage `name`, or `nil`."
  def stage_index(%__MODULE__{index: index}, name), do: Map.get(index, name)

  @doc "The stage names, in order."
  def stage_names(%__MODULE__{stages: stages}),
    do: stages |> Tuple.to_list() |> Enum.map(& &1.name)

  @doc "The current state of stage `name` (for tests and debugging)."
  def stage_state(%__MODULE__{} = core, name) do
    case Map.fetch(core.index, name) do
      {:ok, index} -> elem(core.stages, index).state
      :error -> raise ArgumentError, "no stage named #{inspect(name)}"
    end
  end

  # -- Delivery --

  defp run(core, fun) do
    core = core |> fun.() |> drain()
    {Enum.reverse(core.commands), %{core | commands: []}}
  end

  defp drain(core) do
    case next(core) do
      {:empty, core} ->
        core

      {{index, frame, direction}, core} ->
        core
        |> Map.put(:current, frame)
        |> deliver(index, frame, direction)
        |> Map.put(:current, nil)
        |> drain()
    end
  end

  # An `UpdateStage` for this stage goes to `handle_update/2` and stops here.
  defp deliver(core, index, %Frames.UpdateStage{stage: name, opts: opts} = frame, direction) do
    stage = elem(core.stages, index)

    cond do
      stage.name != name ->
        call(core, index, :handle_frame, [frame, direction])

      function_exported?(stage.module, :handle_update, 2) ->
        call(core, index, :handle_update, [opts])

      true ->
        effect(core, index, {:error, {:not_updatable, Keyword.keys(opts)}, false})
    end
  end

  defp deliver(core, index, frame, direction),
    do: call(core, index, :handle_frame, [frame, direction])

  # System frames go first.
  defp next(core) do
    case :queue.out(core.system) do
      {{:value, entry}, system} ->
        {entry, %{core | system: system}}

      {:empty, _} ->
        case :queue.out(core.queue) do
          {{:value, entry}, queue} -> {entry, %{core | queue: queue}}
          {:empty, _} -> {:empty, core}
        end
    end
  end

  # Sends a frame pushed by stage `from` to its neighbour.
  defp route(core, from, frame, direction) do
    {frame, core} = assign_id(frame, core)
    core = maybe_observe(core, frame)

    cond do
      match?(%Frames.Interruption{}, frame) ->
        interrupt(core, frame)

      direction == :downstream and from + 1 >= tuple_size(core.stages) ->
        command(core, {:output, frame})

      direction == :upstream and from - 1 < 0 ->
        command(core, {:output_upstream, frame})

      true ->
        target = if direction == :downstream, do: from + 1, else: from - 1
        enqueue(core, {target, frame, direction})
    end
  end

  defp maybe_observe(core, %module{} = frame) do
    if MapSet.member?(core.observed, module), do: command(core, {:observe, frame}), else: core
  end

  defp enqueue(core, {_index, frame, _direction} = entry) do
    if Frame.system?(frame),
      do: %{core | system: :queue.in(entry, core.system)},
      else: %{core | queue: :queue.in(entry, core.queue)}
  end

  defp assign_id(%{id: nil} = frame, core) do
    seq = core.seq + 1
    {%{frame | id: seq}, %{core | seq: seq}}
  end

  defp assign_id(frame, core), do: {frame, core}

  defp command(core, command), do: %{core | commands: [command | core.commands]}

  # -- Callbacks and effects --

  defp call(core, index, fun, args, on_effects \\ nil) do
    stage = elem(core.stages, index)
    trace? = fun == :handle_frame and hd(args).__struct__ not in @untraced
    meta = if trace?, do: trace_start(core, stage, hd(args))

    {effects, state} =
      try do
        case apply(stage.module, fun, args ++ [stage.state]) do
          {effects, state} when is_list(effects) ->
            {effects, state}

          other ->
            raise ArgumentError,
                  "#{inspect(stage.module)}.#{fun} must return {effects, state}, got: #{inspect(other)}"
        end
      rescue
        error ->
          Logger.error(
            "#{inspect(stage.name)} #{fun} failed: " <>
              Exception.format(:error, error, __STACKTRACE__)
          )

          if meta, do: trace_exception(meta, error)
          {[{:error, error, false}], stage.state, :failed}
      end
      |> case do
        {effects, state, :failed} ->
          {effects, state}

        {effects, state} ->
          if meta, do: trace_stop(meta)
          {effects, state}
      end

    core = %{core | stages: put_elem(core.stages, index, %{stage | state: state})}
    core = if on_effects, do: on_effects.(core, effects), else: core
    Enum.reduce(effects, core, &effect(&2, index, &1))
  end

  defp effect(core, index, {:push, frame, direction})
       when is_struct(frame) and direction in [:downstream, :upstream],
       do: route(core, index, frame, direction)

  defp effect(core, index, {:async, key, fun}) when is_function(fun, 1),
    do: effect(core, index, {:async, key, fun, %{}})

  defp effect(core, index, {:async, key, fun, extra_meta})
       when is_function(fun, 1) and is_map(extra_meta) do
    core = effect(core, index, {:cancel, key})
    {id, core} = new_id(core, index, key)
    keep? = core.current != nil and Frame.uninterruptible?(core.current)
    stage = elem(core.stages, index)
    {started, meta} = async_start(core, stage, id, key, keep?, extra_meta)

    task = %{
      id: id,
      keep?: keep?,
      started: started,
      first_output_at: nil,
      outputs: 0,
      meta: meta
    }

    %{core | tasks: Map.put(core.tasks, {index, key}, task)}
    |> command({:start_task, id, fun})
  end

  defp effect(core, index, {:cancel, key}) do
    case Map.pop(core.tasks, {index, key}) do
      {nil, _tasks} ->
        core

      {task, tasks} ->
        async_stop(task, :cancelled)
        command(%{core | tasks: tasks}, {:kill_task, task.id})
    end
  end

  defp effect(core, index, {:timer, key, ms}) when is_integer(ms) and ms >= 0 do
    core = effect(core, index, {:cancel_timer, key})
    {id, core} = new_id(core, index, key)

    %{core | timers: Map.put(core.timers, {index, key}, id)}
    |> command({:start_timer, id, ms})
  end

  defp effect(core, index, {:cancel_timer, key}) do
    case Map.pop(core.timers, {index, key}) do
      {nil, _timers} -> core
      {id, timers} -> command(%{core | timers: timers}, {:cancel_timer, id})
    end
  end

  defp effect(core, _index, {:notify, event}), do: command(core, {:notify, event})

  defp effect(core, index, {:error, reason, fatal?}) when is_boolean(fatal?) do
    frame = %Frames.Error{
      reason: reason,
      fatal?: fatal?,
      processor: elem(core.stages, index).name
    }

    route(core, index, frame, :upstream)
  end

  defp effect(core, index, other) do
    stage = elem(core.stages, index)
    raise ArgumentError, "#{inspect(stage.module)} returned an invalid effect: #{inspect(other)}"
  end

  defp new_id(core, index, key) do
    seq = core.seq + 1
    {{index, key, seq}, %{core | seq: seq}}
  end

  # -- Interruption --

  # While every stage handles an interruption, the default pass-through (and
  # any other push of an `Interruption`) is ignored: every stage gets it once.
  defp interrupt(%{interrupting?: true} = core, _frame), do: core

  defp interrupt(core, frame) do
    generation = core.generation + 1

    {kept, killed} = Enum.split_with(core.tasks, fn {_key, task} -> task.keep? end)

    core =
      Enum.reduce(killed, core, fn {_key, task}, core ->
        async_stop(task, :interrupted)
        command(core, {:kill_task, task.id})
      end)

    # System frames live in their own queue, which an interruption keeps.
    queue =
      :queue.filter(fn {_index, frame, _dir} -> Frame.uninterruptible?(frame) end, core.queue)

    :telemetry.execute(
      [:octoroom_agent, :pipeline, :interruption],
      %{killed_tasks: length(killed), dropped_frames: :queue.len(core.queue) - :queue.len(queue)},
      base_meta(core, %{generation: generation})
    )

    core =
      %{core | generation: generation, tasks: Map.new(kept), queue: queue, interrupting?: true}
      |> command({:interrupted, generation})

    current = core.current

    core =
      Enum.reduce(0..(tuple_size(core.stages) - 1)//1, %{core | current: nil}, fn index, core ->
        call(core, index, :handle_frame, [frame, :downstream])
      end)

    %{core | interrupting?: false, current: current}
  end

  # -- Telemetry --

  defp base_meta(core, extra) do
    core.telemetry
    |> Map.put(:metadata, core.telemetry)
    |> Map.merge(extra)
  end

  defp trace_start(core, stage, %module{}) do
    meta =
      base_meta(core, %{
        processor: stage.name,
        frame: module,
        generation: core.generation
      })

    start = System.monotonic_time()

    :telemetry.execute(
      [:octoroom_agent, :processor, :frame, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      meta
    )

    {start, meta}
  end

  defp trace_stop({start, meta}) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:octoroom_agent, :processor, :frame, :stop],
      %{duration: now - start, monotonic_time: now},
      meta
    )
  end

  defp trace_exception({start, meta}, error) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:octoroom_agent, :processor, :frame, :exception],
      %{duration: now - start, monotonic_time: now},
      Map.merge(meta, %{kind: :error, reason: error})
    )
  end

  defp async_start(core, stage, id, key, keep?, extra_meta) do
    started = System.monotonic_time()

    reserved = %{
      metadata: core.telemetry,
      processor: stage.name,
      module: stage.module,
      task: task_kind(key),
      key: key,
      task_id: id,
      generation: core.generation,
      uninterruptible: keep?
    }

    trigger =
      case core.current do
        %module{} -> %{trigger: module}
        _ -> %{}
      end

    meta =
      extra_meta
      |> Map.merge(trigger)
      |> Map.merge(core.telemetry)
      |> Map.merge(reserved)

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :start],
      %{system_time: System.system_time(), monotonic_time: started},
      meta
    )

    {started, meta}
  end

  defp record_async_output(core, task_key, id, effects) do
    pushed = for {:push, frame, _direction} <- effects, do: frame

    case {pushed, Map.get(core.tasks, task_key)} do
      {[_ | _], %{id: ^id} = task} ->
        task =
          if task.first_output_at == nil do
            now = System.monotonic_time()

            :telemetry.execute(
              [:octoroom_agent, :processor, :async, :first_output],
              %{duration: now - task.started, monotonic_time: now},
              Map.put(task.meta, :frame, hd(pushed).__struct__)
            )

            %{task | first_output_at: now, outputs: task.outputs + length(pushed)}
          else
            %{task | outputs: task.outputs + length(pushed)}
          end

        %{core | tasks: Map.put(core.tasks, task_key, task)}

      _ ->
        core
    end
  end

  defp async_stop(task, outcome) do
    now = System.monotonic_time()

    measurements =
      %{duration: now - task.started, monotonic_time: now, outputs: task.outputs}
      |> maybe_put_first_output(task)

    extra =
      case outcome do
        {:error, reason} -> %{status: :error, reason: reason}
        {:terminated, reason} -> %{status: :terminated, reason: reason}
        status when is_atom(status) -> %{status: status}
      end

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      measurements,
      Map.merge(task.meta, extra)
    )
  end

  defp async_exception(task, reason) do
    now = System.monotonic_time()

    measurements =
      %{duration: now - task.started, monotonic_time: now, outputs: task.outputs}
      |> maybe_put_first_output(task)

    {kind, err_reason} =
      case reason do
        {kind, err} when kind in [:error, :exit, :throw] -> {kind, err}
        other -> {:error, other}
      end

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :exception],
      measurements,
      Map.merge(task.meta, %{kind: kind, reason: err_reason})
    )
  end

  defp maybe_put_first_output(measurements, %{first_output_at: nil}), do: measurements

  defp maybe_put_first_output(measurements, %{first_output_at: at, started: started}),
    do: Map.put(measurements, :first_output_duration, at - started)

  defp done_status({:error, reason}), do: {:error, reason}
  defp done_status(_result), do: :ok

  defp task_kind(key) when is_atom(key), do: key

  defp task_kind(key) when is_tuple(key) and tuple_size(key) > 0 and is_atom(elem(key, 0)),
    do: elem(key, 0)

  defp task_kind(_key), do: :async
end
