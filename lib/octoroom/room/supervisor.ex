defmodule Octoroom.Room.Supervisor do
  @moduledoc false

  # One room's processes, in `rest_for_one` order:
  #
  #   1. Octoroom.Room.Server: state, policy, reconciler, Cloudflare calls
  #   2. DynamicSupervisor: inlets and outlets (adapter socket owners)
  #   3. DynamicSupervisor: the developer's workers
  #
  # The room server is `significant`: when it stops (its last participant
  # left, or it crashed), the whole room shuts down. Until recovery arrives
  # (milestone 4) a crashed room is not restarted. Inlets, outlets and
  # workers are temporary; the room server starts, monitors and restarts
  # them as its reconciler decides.

  use Supervisor, restart: :temporary

  alias Octoroom.Room.Server

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    Supervisor.start_link(__MODULE__, opts, name: via({:room_sup, room_id}))
  end

  def media(room_id), do: via({:media, room_id})
  def workers(room_id), do: via({:workers, room_id})

  defp via(key), do: {:via, Registry, {Octoroom.Registry, key}}

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)

    children = [
      %{
        id: :server,
        start: {Server, :start_link, [opts]},
        restart: :temporary,
        significant: true
      },
      Supervisor.child_spec({DynamicSupervisor, name: media(room_id)}, id: :media),
      Supervisor.child_spec({DynamicSupervisor, name: workers(room_id)}, id: :workers)
    ]

    Supervisor.init(children, strategy: :rest_for_one, auto_shutdown: :any_significant)
  end
end
