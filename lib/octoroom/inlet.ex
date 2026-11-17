defmodule Octoroom.Inlet do
  @moduledoc false

  # One worker input. Owns the socket of an egress adapter that streams an
  # input track's PCM, and forwards each frame to the worker by name. Because
  # it doesn't hold the worker's pid, a restarted worker picks up the same
  # stream and the adapter stays as it is. Frames that arrive while the
  # worker is down are dropped.

  use GenServer, restart: :temporary

  alias Octoroom.{Adapter, Worker}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(%{room_id: room_id, worker_id: worker_id, input: input, ws_id: ws_id}) do
    {:ok, _} = Adapter.register(:egress, ws_id)
    {:ok, %{room_id: room_id, worker_id: worker_id, input: input}}
  end

  @impl true
  def handle_info({:octoroom_pcm, _socket, pcm}, state) do
    case Worker.whereis(state.room_id, state.worker_id) do
      nil -> :ok
      pid -> send(pid, {:octoroom_input, state.input, pcm})
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
