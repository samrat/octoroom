defmodule Meet.Room do
  @moduledoc """
  A video call where everyone hears and sees everyone, with two AI
  assistants that join as soon as the first person does: a general one,
  and Atlas, who only answers questions about capital cities.

  Both hear every mic and everyone hears both. Each uses a decision model
  (`gate: :decision`) on each turn's audio to tell whether it's being
  talked to, so nobody has to say their names. The model is told who they
  are (`name:` and `description:`), so it can tell them apart.
  """
  use Octoroom.Room
  import Octoroom.Agent, only: [agents: 2]

  @agents [
    {"assistant", Meet.Assistant,
     name: "Assistant",
     description:
       "A general assistant for the team."},
    {"atlas", Meet.Atlas,
     name: "Atlas", description: "Answers questions about geography, and nothing else."}
  ]

  @doc "The assistants in every call: `%{id, name}`."
  def assistants, do: for({id, _module, opts} <- @agents, do: %{id: id, name: opts[:name]})

  @impl true
  def join(%{"name" => name}, _socket) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      name -> {:ok, %{name: String.slice(name, 0, 32)}}
    end
  end

  def join(_params, _socket), do: {:error, :name_required}

  @impl true
  def workers(%{participants: []}), do: []

  def workers(room) do
    agents(@agents,
      hears: Enum.map(room.participants, &mic/1),
      respond: :addressed,
      gate: :decision,
      # The model usually answers in about a second, but can take more:
      # wait up to 3 s so every turn in the transcript gets its tags.
      decisions: [max_wait_ms: 3_000]
    )
  end

  @impl true
  def subscriptions(listener, room) do
    people =
      for p <- others(room, listener),
          source <- [&mic/1, &camera/1, &screen/1, &screen_audio/1],
          do: source.(p)

    people ++ for(%{id: id} <- assistants(), do: track(id))
  end
end
