defmodule Octoroom.Participant do
  @moduledoc "A connected client: its id and the metadata its room's `join/2` returned."

  @derive {Jason.Encoder, only: [:id, :meta]}
  @enforce_keys [:id]
  defstruct [:id, meta: %{}]

  @type t :: %__MODULE__{id: String.t(), meta: map}
end
