defmodule Octoroom.Worker.Server do
  @moduledoc false

  # Runs one worker module. Inlets send it room PCM as
  # `{:octoroom_input, input, pcm}`; it converts that to the worker's format,
  # calls `handle_audio/3`, and carries out the returned actions: converting
  # played audio back to room PCM for the output's outlet, flushing, and
  # emitting events. The room server sends `{:octoroom_io, inputs, outputs}`
  # when the worker's spec changes without a restart.

  use GenServer, restart: :temporary

  require Logger

  alias Octoroom.{Audio, Outlet}
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

    ctx = %Context{
      room_id: room_id,
      id: spec.id,
      inputs: spec.inputs,
      outputs: spec.outputs,
      participants: participants,
      resumed: Map.get(opts, :resumed)
    }

    state = %{
      room_id: room_id,
      id: spec.id,
      module: module,
      rate: rate,
      channels: channels,
      out_rate: out_rate,
      out_channels: out_channels,
      inputs: spec.inputs,
      outputs: spec.outputs,
      rest: %{},
      prev: %{},
      user: nil
    }

    case module.init(spec.args, ctx) do
      {:stop, reason} -> {:stop, reason}
      result -> {:ok, handle_result(result, state)}
    end
  end

  @impl true
  def handle_info({:octoroom_input, input, pcm}, state) do
    rest = Map.get(state.rest, input, <<>>)
    {pcm, rest} = from_room(rest <> pcm, state)
    state = put_in(state.rest[input], rest)

    if pcm == <<>>,
      do: {:noreply, state},
      else: {:noreply, state.module.handle_audio(input, pcm, state.user) |> handle_result(state)}
  end

  def handle_info({:octoroom_io, inputs, outputs}, state) do
    old = state
    state = %{state | inputs: inputs, outputs: outputs, rest: Map.take(state.rest, inputs)}

    state =
      if inputs != old.inputs, do: user_info({:octoroom, :inputs, inputs}, state), else: state

    state =
      if outputs != old.outputs, do: user_info({:octoroom, :outputs, outputs}, state), else: state

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

  defp action(other, state),
    do: raise(ArgumentError, "#{inspect(state.module)} returned unknown action #{inspect(other)}")

  defp output!(:default, %{outputs: [first | _]}), do: first

  defp output!(name, state) do
    if name in state.outputs,
      do: name,
      else: raise(ArgumentError, "worker #{inspect(state.id)} has no output #{inspect(name)}")
  end

  # The room's own format needs no conversion.
  defp from_room(pcm, %{rate: 48_000, channels: 2}) do
    size = byte_size(pcm) - rem(byte_size(pcm), 4)
    <<whole::binary-size(size), rest::binary>> = pcm
    {whole, rest}
  end

  defp from_room(pcm, state), do: Audio.from_room(pcm, state.rate, state.channels)

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
