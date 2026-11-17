defmodule Octoroom.Test.Client do
  @moduledoc false

  # Stands in for a participant's channel process: joins a room, then
  # forwards everything the room server sends it to the test as
  # `{:client, name, message}`.

  def join(name, module, room_id, meta, opts),
    do: start(name, fn -> Octoroom.Room.join(module, room_id, meta, opts) end)

  @doc "Comes back with resume data, as a reconnecting channel would."
  def resume(name, module, room_id, data, opts),
    do: start(name, fn -> Octoroom.Room.resume(module, room_id, data, opts) end)

  defp start(name, fun) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:joined, name, fun.()})
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

  @doc "Ends the client's process the way a dropped Phoenix transport does."
  def drop(%{pid: pid}), do: Process.exit(pid, {:shutdown, :closed})

  defp loop(test, name) do
    receive do
      message ->
        send(test, {:client, name, message})
        loop(test, name)
    end
  end
end
