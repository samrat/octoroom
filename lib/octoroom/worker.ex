defmodule Octoroom.Worker do
  @moduledoc """
  A server-side participant: a process that hears input tracks and plays
  output tracks as PCM, with no WebRTC in sight.

      defmodule MyApp.DelayEcho do
        use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

        @impl true
        def init(_args, _ctx), do: {:ok, :queue.new()}

        @impl true
        def handle_audio(_input, pcm, q) do
          q = :queue.in(pcm, q)

          if :queue.len(q) > 100 do
            {{:value, out}, q} = :queue.out(q)
            {:ok, q, play: {:default, out}}
          else
            {:ok, q}
          end
        end
      end

  A room starts workers from its `workers/1` callback (see
  `Octoroom.Room.worker/3`). `audio:` picks the PCM format the worker sees,
  s16le at a `rate` dividing 48 kHz and 1 or 2 `channels` (default 48 kHz
  stereo, the room's own format). The worker plays audio in the same format
  unless `output:` gives another, for a worker that hears at one rate and
  speaks at another:

      use Octoroom.Worker, audio: [rate: 16_000, channels: 1, output: [rate: 24_000]]

  Callbacks return `{:ok, state}` or `{:ok, state, actions}`, where actions
  is a keyword list of:

    * `play: {output, pcm}`: queue `pcm` on an output track. Outputs are
      paced to real time, so a worker can hand over audio faster than it
      plays. `:default` is the worker's first output.
    * `flush: output`: drop that output's queued, unplayed audio (barge-in).
      The worker then gets `handle_info({:octoroom, :flushed, output,
      dropped_ms}, state)`: how many ms of audio were dropped (nil if the
      output's outlet wasn't running), so what it queued minus `dropped_ms`
      is what listeners heard, give or take the frame on its way.
    * `emit: event`: broadcast `{:worker_event, worker_id, event}` to the
      room's `scope: :room` subscribers (see `Octoroom.subscribe/2`).
    * `save: term`: keep `term` in the store (`Octoroom.Store`) as what
      this worker would need to carry on, such as its conversation so far.
      Each save replaces the last. The worker's next start in the same room
      gets it as `ctx.saved`: after a crash, a change of args, or the node
      restarting mid-call. It's deleted when the room stops the worker
      because `workers/1` no longer lists it, and when the room stops
      because its last participant left. Keep it small: it's written on
      every save.

  `handle_info/2` also receives `{:octoroom, :inputs, names}` and
  `{:octoroom, :outputs, names}` when the room changes the worker's inputs or
  outputs; the worker keeps running. A change of module or args restarts it.

  A worker that crashes is restarted by its room, with backoff. Its output
  tracks stay published while it restarts, so listeners hear a gap rather
  than a renegotiation.
  """

  alias Octoroom.Worker.Context

  @type state :: term
  @type actions :: [
          play: {String.t() | :default, binary},
          flush: String.t() | :default,
          emit: term,
          save: term
        ]
  @type result :: {:ok, state} | {:ok, state, actions}

  @callback init(args :: term, ctx :: Context.t()) :: result | {:stop, reason :: term}
  @callback handle_audio(input :: String.t(), pcm :: binary, state) :: result
  @callback handle_info(message :: term, state) :: result
  @callback terminate(reason :: term, state) :: term

  @optional_callbacks handle_info: 2, terminate: 2

  defmacro __using__(opts) do
    audio = Keyword.get(opts, :audio, [])
    rate = Keyword.get(audio, :rate, 48_000)
    channels = Keyword.get(audio, :channels, 2)
    Octoroom.Audio.validate!(rate, channels)
    output = Keyword.get(audio, :output, [])
    out_rate = Keyword.get(output, :rate, rate)
    out_channels = Keyword.get(output, :channels, channels)
    Octoroom.Audio.validate!(out_rate, out_channels)

    quote do
      @behaviour Octoroom.Worker

      @doc false
      def __octoroom_audio__, do: {unquote(rate), unquote(channels)}

      @doc false
      def __octoroom_audio_output__, do: {unquote(out_rate), unquote(out_channels)}

      @impl true
      def handle_info(_message, state), do: {:ok, state}

      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable handle_info: 2, terminate: 2
    end
  end

  @doc "The pid of worker `id` in room `room_id`, or nil."
  def whereis(room_id, id) do
    case Registry.lookup(Octoroom.Registry, {:worker, room_id, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  What worker `id` in room `room_id` last saved (the `save:` action), or
  nil. For apps that show what a worker kept, such as a conversation, while
  the room is down or before its workers have started again.
  """
  def saved(room_id, id, store \\ Octoroom.Store.config()),
    do: Octoroom.Store.get(store, :workers, {room_id, id})

  @doc false
  # Deletes what the worker saved.
  def forget(store, room_id, id), do: Octoroom.Store.delete(store, :workers, {room_id, id})

  @doc false
  # Deletes what every worker of the room saved.
  def forget_room(store, room_id) do
    for {{^room_id, _id} = key, _} <- Octoroom.Store.all(store, :workers),
        do: Octoroom.Store.delete(store, :workers, key)

    :ok
  end

  @doc """
  Sends `message` to a running worker's `handle_info/2`, for example from a
  LiveView. Returns `:ok`, or `{:error, :no_worker}`.
  """
  def send(room_id, id, message) do
    case whereis(room_id, id) do
      nil ->
        {:error, :no_worker}

      pid ->
        Kernel.send(pid, message)
        :ok
    end
  end
end

defmodule Octoroom.Worker.Context do
  @moduledoc """
  What a worker knows when it starts: its room, its id, its input and output
  track names, and the room's participants at that moment. Call
  `Octoroom.Room.state/1` for anything newer.

  `resumed` is set when the worker starts while its room is recovering from
  a crash or restart: `%{gone_ms: ms}`, about how long the room was down.
  A worker that keeps state outside its process (a conversation so far)
  reloads it then.

  `saved` is what this worker last returned in a `save:` action (see
  `Octoroom.Worker`), or nil: it's set after a crash or a change of args as
  well as on recovery.
  """

  defstruct [:room_id, :id, :resumed, :saved, inputs: [], outputs: [], participants: []]

  @type t :: %__MODULE__{
          room_id: String.t(),
          id: String.t(),
          inputs: [String.t()],
          outputs: [String.t()],
          participants: [Octoroom.Participant.t()],
          resumed: nil | %{gone_ms: non_neg_integer},
          saved: term
        }
end
