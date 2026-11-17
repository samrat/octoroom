defmodule Octoroom.Adapter.Socket do
  @moduledoc false

  # The server end of one WebSocket a Cloudflare adapter dials. `:egress`
  # carries a track's PCM to its owner (an inlet); `:ingest` carries the
  # owner's frames to Cloudflare (an outlet). The socket closes when its
  # owner stops.
  #
  # Owner messages: `{:octoroom_adapter_socket, role, socket}` on connect and
  # `{:octoroom_pcm, socket, pcm}` for each egress frame. Owners send
  # `{:octoroom_pcm, frame}` to an ingest socket to publish a frame.

  @behaviour WebSock

  require Logger

  alias Octoroom.Cloudflare.Packet

  @impl true
  def init(%{role: role, owner: owner}) do
    ref = Process.monitor(owner)
    send(owner, {:octoroom_adapter_socket, role, self()})
    {:ok, %{role: role, owner: owner, ref: ref}}
  end

  @impl true
  def handle_in({data, opcode: :binary}, %{role: :egress} = state) do
    case Packet.decode(data) do
      {:ok, %{payload: payload}} when payload != "" ->
        send(state.owner, {:octoroom_pcm, self(), payload})

      {:ok, _packet} ->
        :ok

      {:error, reason} ->
        Logger.warning("Dropping Cloudflare adapter message: #{inspect(reason)}")
    end

    {:ok, state}
  end

  def handle_in(_message, state), do: {:ok, state}

  @impl true
  def handle_info({:octoroom_pcm, frame}, %{role: :ingest} = state),
    do: {:push, {:binary, Packet.encode(frame)}, state}

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:ok, state}
end
