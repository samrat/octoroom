defmodule Octoroom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Octoroom.Registry},
      {Registry, keys: :duplicate, name: Octoroom.Events},
      {Task.Supervisor, name: Octoroom.TaskSupervisor},
      {DynamicSupervisor, name: Octoroom.RoomSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Octoroom.Supervisor)
  end
end
