defmodule Octoroom.Room do
  @moduledoc """
  A room module decides who may join a room and who hears whom.

      defmodule MyApp.TeamRoom do
        use Octoroom.Room

        @impl true
        def join(_params, socket), do: {:ok, %{user_id: socket.assigns.user_id}}
      end

  Only `join/2` is required. `subscriptions/2` defaults to
  `default_subscriptions/2`: every other participant's mic. Both
  `subscriptions/2` and `workers/1` must be pure and fast: they run after
  every room change and read only the `%Octoroom.Room{}` they're given.

  The struct holds the room's `id`, its `participants` in join order (each an
  `Octoroom.Participant`), its running `workers` and its `assigns`.
  """

  alias Octoroom.{Participant, Track}
  alias Octoroom.Room.Server

  defstruct [:id, participants: [], workers: [], assigns: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          participants: [Participant.t()],
          workers: [map],
          assigns: map
        }

  @doc "May this client join, and with what metadata? Runs in the client's channel process."
  @callback join(params :: map, socket :: term) :: {:ok, meta :: map} | {:error, term}

  @doc "Runs once when the room process starts. Returns the room's assigns."
  @callback mount(room_id :: String.t()) :: {:ok, map}

  @doc "Which server-side participants should be running now? (Milestone 3.)"
  @callback workers(t) :: [map]

  @doc "What should `listener` hear now?"
  @callback subscriptions(listener :: Participant.t(), t) :: [Track.t() | String.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Octoroom.Room

      import Octoroom.Room,
        only: [mic: 1, track: 1, gain: 2, others: 2, default_subscriptions: 2, worker: 3]

      @impl true
      def mount(_room_id), do: {:ok, %{}}

      @impl true
      def workers(_room), do: []

      @impl true
      def subscriptions(listener, room), do: Octoroom.Room.default_subscriptions(listener, room)

      defoverridable mount: 1, workers: 1, subscriptions: 2
    end
  end

  ## Policy helpers

  @doc "A participant's mic track."
  def mic(%Participant{id: id}), do: track("#{id}/mic")

  @doc "A track by room-scoped name."
  def track(name) when is_binary(name), do: %Track{name: name}

  @doc "The same track, played at `value` (0.0 to 1.0) in the listener's browser."
  def gain(%Track{} = track, value) when is_number(value) and value >= 0 and value <= 1,
    do: %{track | gain: value / 1}

  @doc "Every participant except `participant`."
  def others(%__MODULE__{participants: ps}, %Participant{id: id}),
    do: Enum.reject(ps, &(&1.id == id))

  @doc "Every other participant's mic, plus every worker output track."
  def default_subscriptions(%Participant{} = listener, %__MODULE__{} = room) do
    mics = room |> others(listener) |> Enum.map(&mic/1)
    outputs = for w <- room.workers, name <- Map.get(w, :outputs, []), do: track(name)
    mics ++ outputs
  end

  @doc "A worker spec. Workers arrive in milestone 3; specs are ignored until then."
  def worker(id, module, opts) when is_binary(id) and is_atom(module) do
    %{
      id: id,
      module: module,
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      args: Keyword.get(opts, :args, %{})
    }
  end

  ## Running rooms

  @doc """
  Adds the calling process to room `room_id` as a participant with `meta`,
  starting the room if needed. The caller is monitored: when it exits, the
  participant leaves.

  Returns `{:ok, %{participant_id, participants, ice_servers}, server}`.
  """
  def join(module, room_id, meta, opts \\ []) do
    join(module, room_id, meta, opts, 2)
  end

  defp join(module, room_id, meta, opts, attempts) do
    with {:ok, server} <- ensure_started(module, room_id, opts),
         {:ok, reply} <- GenServer.call(server, {:join, self(), meta}) do
      {:ok, reply, server}
    end
  catch
    # The room stopped (its last participant left) between lookup and call.
    :exit, _ when attempts > 1 -> join(module, room_id, meta, opts, attempts - 1)
  end

  defp ensure_started(module, room_id, opts) do
    spec = {Server, Keyword.merge(opts, room_id: room_id, module: module)}

    case DynamicSupervisor.start_child(Octoroom.RoomSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc "Updates a participant's metadata with `fun`, then reconciles."
  def update_meta(room_id, participant_id, fun) when is_function(fun, 1),
    do: call(room_id, {:update_meta, participant_id, fun})

  @doc "Sets a room assign, then reconciles."
  def assign(room_id, key, value), do: call(room_id, {:assign, key, value})

  @doc "Re-runs the policy, for policies that read state outside the room."
  def refresh(room_id), do: call(room_id, :refresh)

  @doc """
  A snapshot of the room: its assigns, and for each participant its
  metadata, its mic status and the tracks it currently hears.
  """
  def state(room_id), do: call(room_id, :state)

  defp call(room_id, message) do
    case Server.whereis(room_id) do
      nil -> {:error, :no_room}
      pid -> GenServer.call(pid, message)
    end
  end
end
