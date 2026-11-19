defmodule Meet.Room do
  @moduledoc """
  A video call where everyone hears and sees everyone, with three AI
  assistants that join as soon as the first person does: a general one,
  Atlas, who only answers questions about capital cities, and Gemini, a
  Gemini Live model (`Meet.Gemini`).

  All three hear every mic and everyone hears all three. The first two use a decision model
  (`gate: :decision`, Cloudflare's Clef Flash through OpenRouter) on each
  turn's transcript to tell whether it's being talked to, so nobody has to
  say their names. The model is told who they
  are (`name:` and `description:`), so it can tell them apart, and it
  knows Gemini is there too. Gemini hears everyone mixed and decides for
  itself, so its `gate:` and `respond:` are cleared.
  """
  use Octoroom.Room
  import Octoroom.Agent, only: [agents: 2]

  @agents [
    {"assistant", Meet.Assistant,
     name: "Assistant", description: "A general assistant for the team."},
    {"atlas", Meet.Atlas,
     name: "Atlas", description: "Answers questions about geography, and nothing else."},
    {"gemini", Meet.Gemini,
     name: "Gemini",
     description: "A Gemini Live assistant; answers when someone says its name.",
     gate: nil,
     respond: nil}
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
      # Clef Flash judges the final transcript, so its call adds to every
      # turn's latency; it usually answers in under a second. A turn it
      # hasn't answered after 1.5 s goes on without tags.
      decisions: [model: "openrouter:cloudflare/clef-flash", max_wait_ms: 1_500]
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
