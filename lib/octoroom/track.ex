defmodule Octoroom.Track do
  @moduledoc """
  A subscription to a room-scoped track, such as `"alice/mic"` or
  `"alice/camera"`.

  `kind` is `:audio` or `:video`. Audio is played at `gain` (0.0 to 1.0) in
  the listener's browser; gain doesn't apply to video.

  A participant publishes up to one track per source (see `sources/0`),
  named `"<participant id>/<source>"`. Worker outputs are audio.
  """

  @enforce_keys [:name]
  defstruct [:name, kind: :audio, gain: 1.0]

  @type t :: %__MODULE__{name: String.t(), kind: :audio | :video, gain: float}

  @sources %{"mic" => :audio, "camera" => :video, "screen" => :video, "screen_audio" => :audio}

  @doc "The sources a participant may publish, each with its kind."
  def sources, do: @sources

  @doc "The kind of a source: `:audio`, `:video` or nil for an unknown source."
  def kind(source), do: Map.get(@sources, source)

  @doc "A track by room-scoped name. Participants' camera and screen tracks are video."
  def new(name) when is_binary(name), do: %__MODULE__{name: name, kind: kind_of(name)}

  @doc "A video track by room-scoped name, e.g. for a worker's video output."
  def video(name) when is_binary(name), do: %__MODULE__{name: name, kind: :video}

  @doc "`{participant_id, source}` for a participant's track, or nil (a worker output)."
  def parse(name) when is_binary(name) do
    case String.split(name, "/") do
      [id, source] when is_map_key(@sources, source) -> {id, source}
      _ -> nil
    end
  end

  defp kind_of(name) do
    case parse(name) do
      {_id, source} -> kind(source)
      nil -> :audio
    end
  end
end
