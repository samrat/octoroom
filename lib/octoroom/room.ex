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
  `Octoroom.Participant`), its `workers` (the specs `workers/1` last
  returned) and its `assigns`.
  """

  alias Octoroom.{Participant, Room, Track}
  alias Octoroom.Room.Server

  defstruct [:id, participants: [], workers: [], assigns: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          participants: [Participant.t()],
          workers: [worker_spec],
          assigns: map
        }

  @type worker_spec :: %{
          id: String.t(),
          module: module,
          inputs: [String.t()],
          outputs: [String.t()],
          args: term
        }

  @doc "May this client join, and with what metadata? Runs in the client's channel process."
  @callback join(params :: map, socket :: term) :: {:ok, meta :: map} | {:error, term}

  @doc "Runs once when the room process starts. Returns the room's assigns."
  @callback mount(room_id :: String.t()) :: {:ok, map}

  @doc """
  Which server-side participants should be running now? Each is a
  `worker/3` spec, identified by its id. Octoroom starts and stops workers
  to match. A spec that comes back with other inputs or outputs is updated in
  place; one with another module or args is restarted.
  """
  @callback workers(t) :: [worker_spec]

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

  @doc """
  A worker spec, for `workers/1`:

    * `inputs`: tracks the worker hears (`mic/1`, `track/1` or names).
      An input is connected once its track is live.
    * `outputs`: names of the tracks the worker plays. Output names share a
      namespace with every other track in the room.
    * `args`: passed to the worker's `init/2`.
  """
  def worker(id, module, opts) when is_binary(id) and is_atom(module) do
    %{
      id: id,
      module: module,
      inputs: opts |> Keyword.get(:inputs, []) |> Enum.map(&track_name/1) |> Enum.uniq(),
      outputs: opts |> Keyword.get(:outputs, []) |> Enum.map(&track_name/1) |> Enum.uniq(),
      args: Keyword.get(opts, :args, %{})
    }
  end

  defp track_name(%Track{name: name}), do: name
  defp track_name(name) when is_binary(name), do: name

  ## Running rooms

  @doc """
  Adds the calling process to room `room_id` as a participant with `meta`,
  starting the room if needed. The caller is monitored: when it exits, the
  participant leaves.

  Returns `{:ok, %{participant_id, participants, ice_servers}, server}`.
  """
  def join(module, room_id, meta, opts \\ []) do
    join(module, room_id, meta, opts, 5)
  end

  defp join(module, room_id, meta, opts, attempts) do
    with {:ok, server} <- ensure_started(module, room_id, opts),
         {:ok, reply} <- GenServer.call(server, {:join, self(), meta}) do
      {:ok, reply, server}
    end
  catch
    # The room stopped (its last participant left) between lookup and call,
    # and its supervisor may still be shutting down.
    :exit, _ when attempts > 1 ->
      Process.sleep(10)
      join(module, room_id, meta, opts, attempts - 1)
  end

  defp ensure_started(module, room_id, opts) do
    spec = {Room.Supervisor, Keyword.merge(opts, room_id: room_id, module: module)}

    case DynamicSupervisor.start_child(Octoroom.RoomSupervisor, spec) do
      {:ok, _} -> server!(room_id)
      {:error, {:already_started, _}} -> server!(room_id)
      error -> error
    end
  end

  defp server!(room_id) do
    case Server.whereis(room_id) do
      nil -> exit(:room_stopping)
      pid -> {:ok, pid}
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
  catch
    # The room stopped (its last participant left) after the lookup.
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> {:error, :no_room}
  end
end
