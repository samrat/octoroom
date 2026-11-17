defmodule Octoroom.Agent.Pipeline.Host do
  @moduledoc false

  # Carries out a core's task and timer commands in the calling process, and
  # turns the resulting messages back into core calls. Used by
  # `Octoroom.Agent.Worker`.
  #
  # Each task replies through its own process alias. Killing a task unaliases
  # it, so the runtime drops anything the task still sends.

  alias Octoroom.Agent.Pipeline.Core

  defstruct tasks: %{}, timers: %{}

  def new, do: %__MODULE__{}

  @doc "Runs a task, timer or kill command. Returns `:unhandled` for any other command."
  def execute(%__MODULE__{} = host, {:start_task, id, fun}) do
    reply_to = Process.alias()
    emit = fn message -> send(reply_to, {:octoroom_agent_task, id, message}) && :ok end

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:done, fun.(emit)}
          rescue
            error -> {:failed, error}
          catch
            kind, reason -> {:failed, {kind, reason}}
          end

        send(reply_to, {:octoroom_agent_task, id, result})
      end)

    {:ok, %{host | tasks: Map.put(host.tasks, id, {pid, monitor, reply_to})}}
  end

  def execute(%__MODULE__{} = host, {:kill_task, id}), do: {:ok, kill(host, id)}

  def execute(%__MODULE__{} = host, {:start_timer, id, ms}) do
    ref = Process.send_after(self(), {:octoroom_agent_timer, id}, ms)
    {:ok, %{host | timers: Map.put(host.timers, id, ref)}}
  end

  def execute(%__MODULE__{} = host, {:cancel_timer, id}) do
    case Map.pop(host.timers, id) do
      {nil, _timers} ->
        {:ok, host}

      {ref, timers} ->
        Process.cancel_timer(ref)
        {:ok, %{host | timers: timers}}
    end
  end

  def execute(%__MODULE__{}, _command), do: :unhandled

  @doc """
  Handles a task, timer or processor message. Returns `{commands, core, host}`,
  or `:unknown` for other messages.

  `unwrap` maps the id a command was executed with back to the core's own.
  A host process running several cores tags each core's ids before
  `execute/2` (so they can't collide) and passes the untagging here.
  """
  def handle_message(host, core, message, unwrap \\ &Function.identity/1)

  def handle_message(%__MODULE__{} = host, core, {:octoroom_agent_task, id, message}, unwrap) do
    host =
      if match?({:done, _}, message) or match?({:failed, _}, message),
        do: forget(host, id),
        else: host

    {commands, core} = Core.async_message(core, unwrap.(id), message)
    {commands, core, host}
  end

  # A task that died without reporting (killed from outside, or a link).
  def handle_message(%__MODULE__{} = host, core, {:DOWN, monitor, :process, _pid, reason}, unwrap) do
    case Enum.find(host.tasks, fn {_id, {_pid, mon, _alias}} -> mon == monitor end) do
      {id, _task} ->
        host = forget(host, id)
        {commands, core} = Core.async_message(core, unwrap.(id), {:failed, reason})
        {commands, core, host}

      nil ->
        :unknown
    end
  end

  def handle_message(%__MODULE__{} = host, core, {:octoroom_agent_timer, id}, unwrap) do
    host = %{host | timers: Map.delete(host.timers, id)}
    {commands, core} = Core.timer_fired(core, unwrap.(id))
    {commands, core, host}
  end

  def handle_message(
        %__MODULE__{} = host,
        core,
        {:octoroom_agent_processor_info, path, message},
        _unwrap
      ) do
    {commands, core} = Core.info(core, path, message)
    {commands, core, host}
  end

  def handle_message(%__MODULE__{}, _core, _message, _unwrap), do: :unknown

  @doc "Kills every task and cancels every timer."
  def stop(%__MODULE__{} = host) do
    host = Enum.reduce(Map.keys(host.tasks), host, &kill(&2, &1))
    Enum.each(host.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    %{host | timers: %{}}
  end

  defp kill(host, id) do
    case Map.pop(host.tasks, id) do
      {nil, _tasks} ->
        host

      {{pid, monitor, reply_to}, tasks} ->
        Process.unalias(reply_to)
        Process.demonitor(monitor, [:flush])
        # `:shutdown` rather than `:kill`, so linked helpers (HTTP streams)
        # stop quietly instead of logging a crash.
        Process.exit(pid, :shutdown)
        %{host | tasks: tasks}
    end
  end

  # A finished task: its monitor and alias are no longer needed.
  defp forget(host, id) do
    case Map.pop(host.tasks, id) do
      {nil, _tasks} ->
        host

      {{_pid, monitor, reply_to}, tasks} ->
        Process.demonitor(monitor, [:flush])
        Process.unalias(reply_to)
        %{host | tasks: tasks}
    end
  end
end
