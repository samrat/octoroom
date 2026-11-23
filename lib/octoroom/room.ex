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

  If one raises, throws, exits or returns the wrong shape, the room keeps its
  last good answer: `workers/1` failing leaves the workers as they are, and
  `subscriptions/2` failing for a listener leaves that listener's
  subscriptions as they are (tracks that stop being published still close).
  The failure is logged, broadcast as `{:error, {:policy, callback},
  reason}` and emitted as `[:octoroom, :policy, :error]` telemetry, once
  each time it starts or changes.

  The struct holds the room's `id`, its `participants` in join order (each an
  `Octoroom.Participant`), its `workers` (the specs `workers/1` last
  returned) and its `assigns`.

  ## Publishing

  A participant publishes up to one track per source: `"mic"`, `"camera"`,
  `"screen"` and `"screen_audio"`, named `"<id>/<source>"` in the room
  (`mic/1`, `camera/1`, `screen/1`, `screen_audio/1`). By default it may
  publish any of them; a `:publish` key in the metadata `join/2` returns
  limits it, e.g. `%{name: name, publish: ["mic"]}` for audio only. The room
  server refuses any other source. Metadata must be a map, and `:publish` (or
  `"publish"`) a list of strings when present; a join with anything else is
  refused. What a participant publishes right now
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
          data: [String.t()],
          args: term
        }

  @doc "May this client join, and with what metadata? Runs in the client's channel process."
  @callback join(params :: map, socket :: term) :: {:ok, meta :: map} | {:error, term}

  @doc """
  Runs once when the room process starts. Returns the room's assigns. If it
  raises or returns anything else, the room doesn't start, and the join
  that started it fails with `{:error, {:mount_failed, reason}}`.
  """
  @callback mount(room_id :: String.t()) :: {:ok, map}

  @doc """
  Which server-side participants should be running now? Each is a
  `worker/3` spec, identified by its id. Octoroom starts and stops workers
  to match. A spec that comes back with other inputs, outputs or data
  outputs is updated in place; one with another module or args is restarted.
  """
  @callback workers(t) :: [worker_spec]

  @doc "What should `listener` hear now?"
  @callback subscriptions(listener :: Participant.t(), t) :: [Track.t() | String.t()]

  @doc """
  May `sender` send worker `worker_id` a message from its client? Only
  asked for a sender the worker hears (one of its tracks is among the
  worker's inputs): others are refused before this runs, so it can only
  narrow that rule. Without it, everyone the worker hears may. A raise
  counts as no.
  """
  @callback message(sender :: Participant.t(), worker_id :: String.t(), t) :: boolean

  @optional_callbacks message: 3

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

    outputs =
      for w <- room.workers,
          name <- Map.get(w, :outputs, []) ++ Map.get(w, :data, []),
          do: track(name)

    published ++ outputs
  end

  @doc """
  A worker spec, for `workers/1`:

    * `inputs`: audio tracks the worker hears (`mic/1`, `track/1` or
      names). An input is connected once its track is live. Workers don't
      take video yet.
    * `outputs`: names of the tracks the worker plays. Output names share a
      namespace with every other track in the room.
    * `data`: names of data-only outputs, for a worker with something to
      tell clients but nothing to play (a notetaker, a captioner). They
      share the same namespace, and `subscriptions/2` lists them like
      tracks, but they carry no media: subscribing to one never touches
      Cloudflare, and it applies as soon as the participant has joined,
      before its media is up.
    * `args`: passed to the worker's `init/2`.
  """
  def worker(id, module, opts) when is_binary(id) and is_atom(module) do
    inputs = opts |> Keyword.get(:inputs, []) |> Enum.map(&track_name/1) |> Enum.uniq()
    video_inputs = Keyword.get(opts, :video_inputs, :client)

    unless video_inputs in [:client, :rtp] do
      raise ArgumentError,
            "worker #{id}: video_inputs: must be :client or :rtp, got #{inspect(video_inputs)}"
    end

    video = Enum.find(inputs, &(Track.new(&1).kind == :video))

    if video && video_inputs == :client && Octoroom.Worker.video_config(module) == nil do
      raise ArgumentError,
            "worker #{id}: #{video} is video, and #{inspect(module)} doesn't accept video inputs " <>
              "(opt in with `use Octoroom.Worker, video: [source: :client]` or `video_inputs: :rtp`)"
    end

    {outputs, output_kinds} = parse_outputs(Keyword.get(opts, :outputs, []))
    data = opts |> Keyword.get(:data, []) |> Enum.uniq()

    if bad = Enum.find(data, &(not is_binary(&1))),
      do: raise(ArgumentError, "worker #{id}: data output #{inspect(bad)} isn't a string")

    if both = Enum.find(data, &(&1 in outputs)),
      do: raise(ArgumentError, "worker #{id}: #{both} is both an output and a data output")

    spec = %{
      id: id,
      module: module,
      inputs: inputs,
      outputs: outputs,
      data: data,
      args: Keyword.get(opts, :args, %{})
    }

    spec =
      if map_size(output_kinds) == 0, do: spec, else: Map.put(spec, :output_kinds, output_kinds)

    if video_inputs == :rtp, do: Map.put(spec, :video_inputs, :rtp), else: spec
  end

  defp parse_outputs(list) do
    {names, kinds} =
      Enum.reduce(list, {[], %{}}, fn item, {names, kinds} ->
        {name, kind} = output_entry(item)

        if name in names do
          {names, kinds}
        else
          kinds = if kind == :video, do: Map.put(kinds, name, :video), else: kinds
          {[name | names], kinds}
        end
      end)

    {Enum.reverse(names), kinds}
  end

  defp output_entry(%Track{name: name, kind: kind}), do: {name, kind}
  defp output_entry({:video, name}) when is_binary(name), do: {name, :video}
  defp output_entry({:audio, name}) when is_binary(name), do: {name, :audio}
  defp output_entry(name) when is_binary(name), do: {name, Track.new(name).kind}

  defp track_name(%Track{name: name}), do: name
  defp track_name(name) when is_binary(name), do: name

  ## Running rooms

  @doc """
  Adds the calling process to room `room_id` as a participant with `meta`,
  starting the room if needed. The caller is monitored: when it exits, the
  participant leaves.

  Returns `{:ok, reply, server}`, where `reply` has `participant_id`,
  `participants`, `ice_servers`, `resumed` (false) and `resume`: the data a
  resume token carries (see `resume/4`). Metadata that isn't a map, or whose
  `:publish` isn't a list of source names, is refused with
  `{:error, {:bad_meta, meta}}`.
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
      {:ok, _} ->
        server!(room_id)

      {:error, {:already_started, _}} ->
        server!(room_id)

      {:error, {:shutdown, {:failed_to_start_child, :server, {:mount_failed, _} = e}}} ->
        {:error, e}

      error ->
        error
    end
  end

  defp server!(room_id) do
    case Server.whereis(room_id) do
      nil -> exit(:room_stopping)
      pid -> {:ok, pid}
    end
  end

  @doc """
  Updates a participant's metadata with `fun`, then reconciles. `fun` runs
  in the room server.

  Returns `:ok`, `{:error, :no_participant}`, or `{:error, reason}` when
  `fun` raises, throws or exits (`reason` is the exception, `{:throw, value}`
  or `{:exit, reason}`) or returns something other than a map whose
  `:publish`, if present, is a list of source names (`{:bad_return, value}`). The metadata is then left as it was, and the
  failure is logged and broadcast as `{:error, {:policy, :update_meta},
  reason}`.
  """
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
