defmodule Meet.Assistant do
  @moduledoc """
  The general assistant in every call, alongside `Meet.Atlas`. `Meet.Room`
  adds both with `agents/2`.
  """
  use Octoroom.Agent

  alias Octoroom.Agent.Tool

  @impl true
  def instructions(_ctx) do
    """
    You are Assistant, one of two AI assistants in a group video call; the other, Atlas,
    answers questions about capital cities. Each line from the call starts with the
    speaker's name in brackets. People mostly talk to each other; only answer when someone
    addresses you, or when a question is left open that you can answer. Your replies are
    spoken aloud: a sentence or two, no markdown, and don't start with a name tag.
    """
  end

  @impl true
  def tools(_ctx) do
    [
      %Tool{
        name: "set_theme",
        description:
          "Switch the call page between light and dark mode, for everyone in the call.",
        parameters: %{
          type: "object",
          properties: %{
            theme: %{
              type: "string",
              enum: ["light", "dark"],
              description: "The theme to switch to."
            }
          },
          required: ["theme"]
        },
        handler: {__MODULE__, :set_theme}
      }
    ]
  end

  # Runs in the agent's process, on this node: it can broadcast to the
  # room's LiveViews like any other Phoenix code.
  def set_theme(call, ctx) do
    args = Map.get(call, :args) || %{}

    response =
      case args["theme"] || args[:theme] do
        theme when theme in ["light", "dark"] ->
          Phoenix.PubSub.broadcast(Meet.PubSub, "theme:#{ctx.room_id}", {:set_theme, theme})
          %{result: "ok", theme: theme}

        other ->
          %{result: "error", reason: "theme must be light or dark, got #{inspect(other)}"}
      end

    %{id: call.id, name: call.name, response: response}
  end
end
