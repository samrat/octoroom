defmodule Octoroom.Track do
  @moduledoc """
  A subscription to a room-scoped track, such as `"alice/mic"`, played at
  `gain` (0.0 to 1.0) in the listener's browser.
  """

  @enforce_keys [:name]
  defstruct [:name, gain: 1.0]

  @type t :: %__MODULE__{name: String.t(), gain: float}
end
