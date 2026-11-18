defmodule Octoroom.Worker.Server do
  @moduledoc false

  # Runs one worker module. Inlets send it PCM already in the worker's
  # format as `{:octoroom_input, input, pcm, format}`; it calls
  # `handle_audio/3`, and carries out the returned actions: converting
  # played audio back to room PCM for the output's outlet, flushing, and
  # emitting events. `notify` and `presence` go to the room server, which
  # knows who may see them. The room server sends
  # `{:octoroom_io, inputs, outputs, data}` when the worker's spec changes
  # without a restart.

  use GenServer, restart: :temporary

  require Logger

  alias Octoroom.{Audio, Outlet, Store}
  alias Octoroom.Worker.Context

  def start_link(%{room_id: room_id, spec: spec} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(room_id, spec.id))

  def via(room_id, id), do: {:via, Registry, {Octoroom.Registry, {:worker, room_id, id}}}

  @impl true
  def init(%{room_id: room_id, spec: spec, participants: participants} = opts) do
    # So `terminate/2` runs when the room shuts the worker down.
    Process.flag(:trap_exit, true)
    module = spec.module
    {rate, channels} = module.__octoroom_audio__()
    {out_rate, out_channels} = module.__octoroom_audio_output__()
    store = Map.get_lazy(opts, :store, &Store.config/0)

    ctx = %Context{
      room_id: room_id,
      id: spec.id,
      inputs: spec.inputs,
      outputs: spec.outputs,
      participants: participants,
      resumed: Map.get(opts, :resumed),
      saved: Store.get(store, :workers, {room_id, spec.id})
    }

    state = %{
      room_id: room_id,
      server: Map.get(opts, :server),
      id: spec.id,
      module: module,
      store: store,
      rate: rate,
      channels: channels,
      out_rate: out_rate,
      out_channels: out_channels,
      inputs: spec.inputs,
      outputs: spec.outputs,
      data: Map.get(spec, :data, []),
      prev: %{},
      user: nil
    }

    case module.init(spec.args, ctx) do
      {:stop, reason} -> {:stop, reason}
      result -> {:ok, handle_result(result, state)}
    end
  end

  @impl true
  def handle_info({:octoroom_input, input, pcm, {rate, channels}}, state)
      when rate == state.rate and channels == state.channels,
      do: {:noreply, state.module.handle_audio(input, pcm, state.user) |> handle_result(state)}

  # Decoded for the module this worker ran before a restart; the room has
  # told the inlet the new format, and the next frames will be in it.
  def handle_info({:octoroom_input, _input, _pcm, _format}, state), do: {:noreply, state}

  def handle_info({:octoroom_io, inputs, outputs, data}, state) do
    old = state
    state = %{state | inputs: inputs, outputs: outputs, data: data}

    state =
      if inputs != old.inputs, do: user_info({:octoroom, :inputs, inputs}, state), else: state

    state =
      if outputs != old.outputs, do: user_info({:octoroom, :outputs, outputs}, state), else: state

    state = if data != old.data, do: user_info({:octoroom, :data, data}, state), else: state
    {:noreply, state}
  end

  def handle_info(message, state), do: {:noreply, user_info(message, state)}

  @impl true
  def terminate(reason, %{user: user, module: module}), do: module.terminate(reason, user)

  defp user_info(message, state),
    do: state.module.handle_info(message, state.user) |> handle_result(state)

  defp handle_result({:ok, user}, state), do: %{state | user: user}

  defp handle_result({:ok, user, actions}, state),
    do: Enum.reduce(actions, %{state | user: user}, &action/2)

  defp handle_result(other, state) do
    raise ArgumentError,
          "#{inspect(state.module)} returned #{inspect(other)}; expected {:ok, state} or {:ok, state, actions}"
  end

  defp action({:play, {output, pcm}}, state) do
    output = output!(output, state)
    {out, prev} = to_room(pcm, Map.get(state.prev, output, {0, 0}), state)
    Outlet.play(state.room_id, output, out)
    put_in(state.prev[output], prev)
  end

  defp action({:flush, output}, state) do
    output = output!(output, state)
    dropped_ms = Outlet.flush(state.room_id, output)
    # After the callback that asked for it, like any other message.
    send(self(), {:octoroom, :flushed, output, dropped_ms})
    state
  end

  defp action({:emit, event}, state) do
    Octoroom.broadcast(state.room_id, {:worker_event, state.id, event})
    state
  end

  defp action({:notify, {output, type, data}}, state), do: notify(output, type, data, nil, state)

  defp action({:notify, {output, type, data, to}}, state) when is_binary(to),
    do: notify(output, type, data, to, state)

  defp action({:presence, presence}, state) when is_map(presence) do
    status = Map.get(presence, :state)
    attributes = Map.get(presence, :attributes, %{})

    unless is_nil(status) or is_binary(status),
      do: raise(ArgumentError, "presence state must be a string or nil, got #{inspect(status)}")

    unless is_map(attributes),
      do: raise(ArgumentError, "presence attributes must be a map, got #{inspect(attributes)}")

    json!(attributes, "presence attributes")
    tell_room(state, {:presence, status, attributes})
  end

  defp action({:save, data}, state) do
    Store.put(state.store, :workers, {state.room_id, state.id}, data)
    state
  end

  defp action(other, state),
    do: raise(ArgumentError, "#{inspect(state.module)} returned unknown action #{inspect(other)}")

  # Events go to the room server, which delivers them to whoever sees the
  # output; it's checked here, in the worker, that clients can decode them.
  defp notify(output, type, data, to, state) do
    output = notify_output!(output, state)

    unless is_binary(type),
      do: raise(ArgumentError, "notify type must be a string, got #{inspect(type)}")

    unless is_map(data),
      do: raise(ArgumentError, "notify data must be a map, got #{inspect(data)}")

    json!(data, "notify data")
    tell_room(state, {:notify, output, type, data, to})
  end

  defp tell_room(%{server: nil} = state, _message), do: state

  defp tell_room(state, message) do
    send(state.server, {:octoroom_worker, self(), state.id, message})
    state
  end

  defp json!(term, what) do
    case Jason.encode(term) do
      {:ok, _} -> :ok
      {:error, error} -> raise ArgumentError, "#{what} isn't JSON: #{Exception.message(error)}"
    end
  end

  # Any output, audio or data. `:default` is the first.
  defp notify_output!(:default, state) do
    case state.outputs ++ state.data do
      [first | _] -> first
      [] -> raise ArgumentError, "worker #{inspect(state.id)} has no outputs to notify on"
    end
  end

  defp notify_output!(name, state) do
    if name in state.outputs or name in state.data,
      do: name,
      else: raise(ArgumentError, "worker #{inspect(state.id)} has no output #{inspect(name)}")
  end

  defp output!(:default, %{outputs: [first | _]}), do: first

  defp output!(name, state) do
    if name in state.outputs,
      do: name,
      else: raise(ArgumentError, "worker #{inspect(state.id)} has no output #{inspect(name)}")
  end

  # The room's own format needs no conversion.
  defp to_room(pcm, prev, %{out_rate: 48_000, out_channels: 2}) do
    case byte_size(pcm) - rem(byte_size(pcm), 4) do
      0 ->
        {<<>>, prev}

      size ->
        <<l::little-signed-16, r::little-signed-16>> = binary_part(pcm, size - 4, 4)
        {binary_part(pcm, 0, size), {l, r}}
    end
  end

  defp to_room(pcm, prev, state),
    do: Audio.to_room(pcm, state.out_rate, state.out_channels, prev)
end
