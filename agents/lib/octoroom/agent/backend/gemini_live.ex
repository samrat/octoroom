defmodule Octoroom.Agent.Backend.GeminiLive do
  @moduledoc """
  Configuration for a Gemini Live agent: one speech-to-speech model that
  hears everyone mixed into one stream and does its own turn-taking (see
  "Gemini Live" in `Octoroom.Agent.Worker`).

      def backend(_ctx), do: %Octoroom.Agent.Backend.GeminiLive{voice: "Puck"}

  Or as a map, with `gemini_live:` naming it:

      def backend(_ctx), do: %{gemini_live: %{voice: "Puck"}}

  Fields: `:model` (default `#{inspect(Octoroom.Agent.GeminiLive.Protocol.default_model())}`),
  `:voice` (a Gemini prebuilt voice, default `"Zephyr"`) and `:api_key`
  (default `GOOGLE_API_KEY`, then `GEMINI_API_KEY`).
  """

  alias Octoroom.Agent.GeminiLive.Protocol

  defstruct model: Protocol.default_model(), voice: Protocol.default_voice(), api_key: nil

  @type t :: %__MODULE__{}

  @doc "From a map or keyword list with string or atom keys."
  def new(opts \\ %{}) do
    opts = Map.new(opts)

    %__MODULE__{
      model: Protocol.model_name(value(opts, :model)),
      voice: value(opts, :voice) || Protocol.default_voice(),
      api_key: value(opts, :api_key)
    }
  end

  defp value(opts, key), do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  @doc """
  The Gemini Live config a backend names, or nil: a struct, or a map with a
  `gemini_live:` (or `"gemini_live"`) key.
  """
  def from(%__MODULE__{} = backend), do: backend

  def from(opts) when is_map(opts) do
    case value(opts, :gemini_live) do
      nil -> nil
      true -> new()
      config -> new(config)
    end
  end

  def from(_other), do: nil
end
