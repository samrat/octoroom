defmodule Octoroom.Participant do
  @moduledoc """
  A connected client: its id, the metadata its room's `join/2` returned, and
  the tracks it publishes.

  `tracks` maps each live source (`"mic"`, `"camera"`, `"screen"`,
  `"screen_audio"`) to `%{kind: :audio | :video, muted: boolean}`. A source
  that isn't published, or isn't flowing yet, isn't there.
  """

  @derive {Jason.Encoder, only: [:id, :meta, :tracks]}
  @enforce_keys [:id]
  defstruct [:id, meta: %{}, tracks: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          meta: map,
          tracks: %{String.t() => %{kind: :audio | :video, muted: boolean}}
        }
end
