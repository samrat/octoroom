defmodule Octoroom.Agent.ToolResult do
  @moduledoc false

  defstruct [:call_id, :name, response: %{}, event: nil]
end
