defmodule Octoroom.Test.Client do
  @moduledoc false

  # Stands in for a participant's channel process: joins a room, then
  # forwards everything the room server sends it to the test as
  # `{:client, name, message}`.

  def join(name, module, room_id, meta, opts) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:joined, name, Octoroom.Room.join(module, room_id, meta, opts)})
        loop(test, name)
      end)

    receive do
      {:joined, ^name, {:ok, reply, server}} ->
        %{name: name, pid: pid, id: reply.participant_id, server: server, reply: reply}

      {:joined, ^name, other} ->
        raise "join failed: #{inspect(other)}"
    after
      1_000 -> raise "join timed out"
    end
  end

  def stop(%{pid: pid}), do: Process.exit(pid, :kill)

  defp loop(test, name) do
    receive do
      message ->
        send(test, {:client, name, message})
        loop(test, name)
    end
  end
end
