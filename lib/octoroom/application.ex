defmodule Octoroom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {store, store_opts} = Octoroom.Store.config()

    children =
      [
        {Registry, keys: :unique, name: Octoroom.Registry},
        {Registry, keys: :duplicate, name: Octoroom.Events},
        {Task.Supervisor, name: Octoroom.TaskSupervisor},
        store.child_spec(store_opts),
        {DynamicSupervisor, name: Octoroom.RoomSupervisor, strategy: :one_for_one},
        {Octoroom.Janitor, Application.get_env(:octoroom, :janitor, [])}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: Octoroom.Supervisor)
  end
end
