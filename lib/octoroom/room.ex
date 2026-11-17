defmodule Octoroom.Room do
  @moduledoc """
  A room module decides who may join a room and who hears whom.

      defmodule MyApp.TeamRoom do
        use Octoroom.Room

        @impl true
        def join(_params, socket), do: {:ok, %{user_id: socket.assigns.user_id}}
      end

  Only `join/2` is required. `subscriptions/2` defaults to
  `default_subscriptions/2`: every other participant's mic, camera and
  screen share, and every worker output. Both
  `subscriptions/2` and `workers/1` must be pure and fast: they run after
  every room change and read only the `%Octoroom.Room{}` they're given.

  The struct holds the room's `id`, its `participants` in join order (each an
  `Octoroom.Participant`), its `workers` (the specs `workers/1` last
  returned) and its `assigns`.

  ## Publishing

  A participant publishes up to one track per source: `"mic"`, `"camera"`,
  `"screen"` and `"screen_audio"`, named `"<id>/<source>"` in the room
  (`mic/1`, `camera/1`, `screen/1`, `screen_audio/1`). By default it may
  publish any of them; a `:publish` key in the metadata `join/2` returns
  limits it, e.g. `%{name: name, publish: ["mic"]}` for audio only. The room
  server refuses any other source. What a participant publishes right now
  is in its `tracks`.
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
        only: [
          mic: 1,
          camera: 1,
          screen: 1,
          screen_audio: 1,
          track: 1,
          gain: 2,
          others: 2,
          default_subscriptions: 2,
          worker: 3
        ]

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

  @doc "A participant's camera track (video)."
  def camera(%Participant{id: id}), do: track("#{id}/camera")

  @doc "A participant's screen share (video)."
  def screen(%Participant{id: id}), do: track("#{id}/screen")

  @doc "The audio of a participant's screen share, when the browser shares it."
  def screen_audio(%Participant{id: id}), do: track("#{id}/screen_audio")

  @doc "A track by room-scoped name."
  def track(name) when is_binary(name), do: Track.new(name)

  @doc "The same audio track, played at `value` (0.0 to 1.0) in the listener's browser."
  def gain(%Track{kind: :audio} = track, value)
      when is_number(value) and value >= 0 and value <= 1,
      do: %{track | gain: value / 1}

  def gain(%Track{kind: :video, name: name}, _value),
    do: raise(ArgumentError, "gain/2 applies to audio, and #{name} is video")

  @doc "Every participant except `participant`."
  def others(%__MODULE__{participants: ps}, %Participant{id: id}),
    do: Enum.reject(ps, &(&1.id == id))

  @doc """
  Every other participant's tracks (mic, camera, screen share and its
  audio), plus every worker output track. Sources nobody publishes are
  never pulled, so they cost nothing.
  """
  def default_subscriptions(%Participant{} = listener, %__MODULE__{} = room) do
    published =
      for p <- others(room, listener),
          source <- Map.keys(Track.sources()) |> Enum.sort(),
          do: track("#{p.id}/#{source}")

    outputs = for w <- room.workers, name <- Map.get(w, :outputs, []), do: track(name)
    published ++ outputs
  end

  @doc """
  A worker spec, for `workers/1`:

    * `inputs`: audio tracks the worker hears (`mic/1`, `track/1` or
      names). An input is connected once its track is live. Workers don't
      take video yet.
    * `outputs`: names of the tracks the worker plays. Output names share a
      namespace with every other track in the room.
    * `args`: passed to the worker's `init/2`.
  """
  def worker(id, module, opts) when is_binary(id) and is_atom(module) do
    inputs = opts |> Keyword.get(:inputs, []) |> Enum.map(&track_name/1) |> Enum.uniq()

    if video = Enum.find(inputs, &(Track.new(&1).kind == :video)),
      do: raise(ArgumentError, "worker #{id}: #{video} is video, and workers take audio inputs")

    %{
      id: id,
      module: module,
      inputs: inputs,
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

  Returns `{:ok, reply, server}`, where `reply` has `participant_id`,
  `participants`, `ice_servers`, `resumed` (false) and `resume`: the data a
  resume token carries (see `resume/4`).
  """
  def join(module, room_id, meta, opts \\ []) do
    call_starting(module, room_id, {:join, self(), meta}, opts, 5)
  end

  @doc """
  Brings a participant back from its resume data (what the join reply's
  `resume` held, signed into a token by the channel): after its connection
  dropped, after the room server crashed, or after the node restarted.

  If the room still has the participant, only its process is replaced. If
  not (the room was restarted), the participant is re-added with the same id
  and metadata and its Cloudflare session is adopted as it is, so nobody
  renegotiates. `reply.resumed` is false when there was nothing to adopt and
  the client must publish again.
  """
  def resume(module, room_id, data, opts \\ []) do
    call_starting(module, room_id, {:resume, self(), data}, opts, 5)
  end

  defp call_starting(module, room_id, message, opts, attempts) do
    with {:ok, server} <- ensure_started(module, room_id, opts),
         {:ok, reply} <- GenServer.call(server, message) do
      {:ok, reply, server}
    end
  catch
    # The room stopped (its last participant left, or it crashed) between
    # lookup and call, and its supervisor may still be shutting down.
    :exit, _ when attempts > 1 ->
      Process.sleep(10)
      call_starting(module, room_id, message, opts, attempts - 1)
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
  metadata, its connection (`media`), what it publishes (`tracks`: source =>
  `%{status: :pending | :live | :closing, muted: boolean}`; `mic` is the
  mic's status, or `:none`) and the tracks it currently hears.
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
