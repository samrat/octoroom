defmodule Vision.Room do
  @moduledoc """
  One person and a vision-capable voice agent.

  The agent hears the participant's mic (`hears:`) and sees their camera and
  screen share (`sees:`) whenever either is published and unmuted. Switching
  the room's `:mode` assign swaps between `Vision.CascadedAssistant` (Soniox +
  Gemini Flash + TinyVoca) and `Vision.GeminiAssistant` (Gemini Live).
  """
  use Octoroom.Room
  import Octoroom.Agent, only: [agent: 3]

  @impl true
  def mount(_room_id), do: {:ok, %{mode: nil}}

  @impl true
  def join(params, _socket) do
    mode =
      case params["mode"] do
        "gemini_live" -> :gemini_live
        _ -> :cascaded
      end

    {:ok, %{name: "Guest", mode: mode}}
  end

  @impl true
  def workers(%{participants: []}), do: []

  def workers(room) do
    hears = Enum.map(room.participants, &mic/1)
    sees = Enum.flat_map(room.participants, &[camera(&1), screen(&1)])
    mode = room.assigns[:mode] || hd(room.participants).meta[:mode] || :cascaded

    case mode do
      :gemini_live ->
        [
          agent("assistant", Vision.GeminiAssistant,
            name: "Gemini Live",
            hears: hears,
            sees: sees,
            args: %{mode: :gemini_live}
          )
        ]

      _cascaded ->
        [
          agent("assistant", Vision.CascadedAssistant,
            name: "Cascaded",
            hears: hears,
            sees: sees,
            respond: :always,
            args: %{mode: :cascaded}
          )
        ]
    end
  end

  @impl true
  def subscriptions(_listener, _room), do: [track("assistant")]
end
