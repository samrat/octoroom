defmodule Hello.Room do
  @moduledoc """
  One person and a voice agent. Each page opens its own room, so the agent
  only ever talks to one person.

  The agent joins with the person (`workers/1`), hears their mic, and
  answers every turn (`respond: :always`). The person hears only the
  agent (`subscriptions/2`).
  """
  use Octoroom.Room
  import Octoroom.Agent, only: [agent: 3]

  @impl true
  def join(_params, _socket), do: {:ok, %{name: "Guest"}}

  @impl true
  def workers(%{participants: []}), do: []

  def workers(room) do
    [
      agent("assistant", Hello.Assistant,
        hears: Enum.map(room.participants, &mic/1),
        respond: :always
      )
    ]
  end

  @impl true
  def subscriptions(_listener, _room), do: [track("assistant")]
end
