defmodule OctoroomTest do
  use ExUnit.Case, async: true

  test "the application starts" do
    assert Process.whereis(Octoroom.Supervisor)
  end
end
