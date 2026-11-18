defmodule Call.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    cf = Application.get_env(:octoroom, :cloudflare, [])

    if cf[:app_id] in [nil, ""] or cf[:app_secret] in [nil, ""],
      do: raise("Set OCTOROOM_CLOUDFLARE_APP_ID and OCTOROOM_CLOUDFLARE_APP_SECRET (see README)")

    children = [{Phoenix.PubSub, name: Call.PubSub}, Call.Presence, Call.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: Call.Supervisor)
  end
end

defmodule Call.Presence do
  @moduledoc "Who has this room's page open, in the call or not."
  use Phoenix.Presence, otp_app: :call, pubsub_server: Call.PubSub
end

defmodule Call.Room do
  @moduledoc """
  A group call with video and a mic check: everyone hears and sees
  everyone (cameras and screen shares), except that a participant who turns
  "receive video" off gets audio only, plus

    * a private two-second echo for each participant who turns it on, which
      only they hear;
    * a room-wide metronome, when the room's `:metronome` assign is set;
    * a recorder hearing every mic, when the room's `:recording` assign is set;
    * live captions of every mic, when the room's `:captions` assign is set
      (needs `SONIOX_API_KEY`);
    * a call assistant, when the room's `:assistant` assign is set: one
      voice agent that hears every mic and everyone hears, configured from
      the agent lab at `/lab/<room>` (needs `SONIOX_API_KEY`,
      `GOOGLE_API_KEY` and `INWORLD_API_KEY`).
  """
  use Octoroom.Room

  @impl true
  def join(%{"name" => name}, _socket) when is_binary(name) do
    case String.trim(name) do
      "" ->
        {:error, :name_required}

      name ->
        {:ok, %{name: String.slice(name, 0, 32), echo: false, video: true}}
    end
  end

  def join(_params, _socket), do: {:error, :name_required}

  @impl true
  def workers(room) do
    echoes =
      for %{meta: %{echo: true}} = p <- room.participants do
        worker("echo:#{p.id}", Call.DelayEcho, inputs: [mic(p)], outputs: [echo(p)])
      end

    metronome =
      if room.assigns[:metronome],
        do: [worker("metronome", Call.Metronome, outputs: ["metronome"])],
        else: []

    recorder =
      if room.assigns[:recording] && room.participants != [],
        do: [worker("recorder", Call.Recorder, inputs: Enum.map(room.participants, &mic/1))],
        else: []

    captioner =
      if room.assigns[:captions] && room.participants != [] && captions_available?(),
        do: [worker("captioner", Call.Captioner, inputs: Enum.map(room.participants, &mic/1))],
        else: []

    assistant =
      if room.assigns[:assistant] && room.participants != [] && assistant_available?(),
        do: [
          # Settings come from the agent lab (`Call.LabLive`); changing them
          # changes the args, which restarts the assistant.
          Octoroom.Agent.agent(
            "assistant",
            Call.Assistant,
            [hears: Enum.map(room.participants, &mic/1)] ++
              (room.assigns |> Call.Agent.config() |> Call.Agent.opts())
          )
        ],
        else: []

    metronome ++ echoes ++ recorder ++ captioner ++ assistant
  end

  def captions_available?, do: Application.get_env(:call, :soniox_api_key) not in [nil, ""]
  def assistant_available?, do: Application.get_env(:call, :assistant?, false)

  @impl true
  def subscriptions(listener, room) do
    # Video is only pulled for listeners who want it: the server decides,
    # so an audio-only listener never downloads anyone's camera.
    sources =
      if listener.meta.video,
        do: [&mic/1, &camera/1, &screen/1, &screen_audio/1],
        else: [&mic/1, &screen_audio/1]

    mics = for p <- others(room, listener), source <- sources, do: source.(p)
    own_echo = if listener.meta.echo, do: [track(echo(listener))], else: []
    assistant = if room.assigns[:assistant], do: [track("assistant")], else: []
    metronome = if room.assigns[:metronome], do: [track("metronome")], else: []
    mics ++ own_echo ++ assistant ++ metronome
  end

  def echo(participant), do: "#{participant.id}/echo"
end

defmodule Call.RoomChannel do
  use Octoroom.Phoenix.Channel, room: Call.Room
end

defmodule Call.UserSocket do
  use Phoenix.Socket

  channel "room:*", Call.RoomChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end

defmodule Call.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Octoroom call</title>
        <style>
          :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #fff; --card: #f5f5f7; --accent: #f38020; --ok: #2f9e44; }
          @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #98989d; --bg: #111; --card: #1c1c1e; } }
          body { font: 15px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 0; }
          main { max-width: 860px; margin: 0 auto; padding: 24px 16px; }
          h1 { font-size: 22px; margin: 0 0 4px; }
          .sub { color: var(--muted); margin: 0 0 20px; }
          .controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; background: var(--card); padding: 12px; border-radius: 10px; }
          input[type=text] { font: inherit; padding: 6px 10px; border-radius: 6px; border: 1px solid #8884; background: var(--bg); color: var(--fg); }
          button { font: inherit; padding: 6px 14px; border-radius: 6px; border: 0; background: var(--accent); color: #fff; cursor: pointer; }
          button:disabled { opacity: .4; cursor: default; }
          button.secondary { background: #8883; color: var(--fg); }
          #status { color: var(--muted); font-size: 13px; width: 100%; }
          table { width: 100%; border-collapse: collapse; margin-top: 20px; }
          th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid #8883; vertical-align: top; }
          th { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); font-weight: 600; }
          .you { color: var(--accent); font-size: 12px; margin-left: 4px; }
          .pill { font-size: 12px; padding: 1px 8px; border-radius: 99px; background: #8883; }
          .pill.live { background: var(--ok); color: #fff; }
          .meter { display: inline-block; width: 80px; height: 8px; background: #8883; border-radius: 4px; overflow: hidden; vertical-align: middle; }
          .meter > span { display: block; height: 100%; width: 0; background: var(--ok); transition: width .15s; }
          .empty { color: var(--muted); margin-top: 20px; }
          .workers { margin-top: 12px; }
          .recorded { margin-top: 16px; display: flex; flex-wrap: wrap; gap: 12px; }
          .recorded .dir { width: 100%; color: var(--muted); font-size: 12px; font-family: ui-monospace, monospace; }
          .viewers { color: var(--muted); font-size: 13px; margin: 12px 0 0; }
          .captions { background: var(--card); border-radius: 10px; padding: 8px 12px; margin-top: 12px; }
          .captions .line { margin: 4px 0; }
          .captions .partial { color: var(--muted); }
          .hint { color: var(--muted); font-size: 13px; }
          details.tools { margin-top: 16px; border: 1px solid #8883; border-radius: 10px; padding: 8px 12px; }
          details.tools > summary { cursor: pointer; color: var(--muted); font-size: 14px; }
          details.tools[open] > summary { margin-bottom: 8px; }
          a { color: var(--accent); }
          .lab { display: grid; grid-template-columns: 300px 1fr; gap: 16px; margin-top: 16px; align-items: start; }
          @media (max-width: 760px) { .lab { grid-template-columns: 1fr; } }
          .panel { background: var(--card); border-radius: 10px; padding: 12px 14px; }
          .panel h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin: 0 0 8px; }
          .panel fieldset { border: 0; padding: 0; margin: 0 0 14px; }
          .panel legend { font-weight: 600; margin-bottom: 4px; }
          .panel label.opt { display: block; margin: 4px 0; }
          .panel label.opt small, .panel .note { display: block; color: var(--muted); font-size: 12px; margin-left: 22px; }
          .panel .note { margin-left: 0; }
          .panel .range { display: grid; grid-template-columns: 1fr 52px; gap: 6px; align-items: center; font-size: 13px; margin: 6px 0; }
          .panel .range span { grid-column: 1 / -1; }
          .panel .range output { font-family: ui-monospace, monospace; text-align: right; }
          .feed .entry { padding: 8px 0; border-bottom: 1px solid #8882; }
          .feed .entry:last-child { border-bottom: 0; }
          .feed .who { font-weight: 600; }
          .feed .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 4px; font-size: 12px; }
          .chip { padding: 1px 8px; border-radius: 99px; background: #8883; font-family: ui-monospace, monospace; }
          .chip.reply { background: var(--ok); color: #fff; }
          .chip.wait { background: var(--accent); color: #fff; }
          .feed .latency { color: var(--muted); font-size: 12px; font-family: ui-monospace, monospace; margin-top: 2px; }
          .status-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
          .videos { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 8px; margin-top: 12px; }
          .videos:empty { display: none; }
          .tile { position: relative; aspect-ratio: 16 / 9; background: #000; border-radius: 8px; overflow: hidden; }
          .tile video { width: 100%; height: 100%; object-fit: cover; display: block; }
          .tile.screen video { object-fit: contain; }
          .tile.mirror video { transform: scaleX(-1); }
          .tile .label { position: absolute; left: 6px; bottom: 6px; font-size: 12px; color: #fff; background: #0008; padding: 1px 6px; border-radius: 4px; }
          .tile .paused { position: absolute; inset: 0; display: none; place-items: center; color: #fff; background: #222; font-size: 13px; }
          .tile.muted .paused { display: grid; }
        </style>
        <script type="importmap">
          {"imports": {
            "phoenix": "/assets/phoenix/phoenix.mjs",
            "phoenix_live_view": "/assets/lv/phoenix_live_view.esm.js",
            "octoroom": "/assets/octoroom/octoroom.mjs"
          }}
        </script>
        <script type="module" src="/assets/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule Call.Components do
  @moduledoc "Pieces both pages use."
  use Phoenix.Component

  @doc "Join, mute, camera and screen controls, run by the `Call` hook in app.js."
  attr :room, :string, required: true

  def call_controls(assigns) do
    ~H"""
    <div id="call" class="controls" phx-hook="Call" phx-update="ignore" data-room={@room}>
      <input id="name" type="text" placeholder="Your name" />
      <label><input id="tone" type="checkbox" /> test tone instead of mic</label>
      <label><input id="pattern" type="checkbox" /> test pattern instead of camera</label>
      <label><input id="join-camera" type="checkbox" /> join with camera</label>
      <button id="join">Join call</button>
      <button id="mute" class="secondary" disabled>Mute</button>
      <button id="camera" class="secondary" disabled>Camera on</button>
      <button id="pause" class="secondary" disabled>Pause video</button>
      <button id="screen" class="secondary" disabled>Share screen</button>
      <button id="leave" class="secondary" disabled>Leave</button>
      <div id="status">Not in the call.</div>
    </div>
    """
  end

  @doc "The page for `room`: `path(\"lobby\", \"\")` is `/`, others `/r/<room>`."
  def path("lobby", ""), do: "/"
  def path(room, ""), do: "/r/#{room}"
  def path("lobby", "lab"), do: "/lab"
  def path(room, "lab"), do: "/lab/#{room}"
end

defmodule Call.CallLive do
  use Phoenix.LiveView
  import Call.Components

  @impl true
  def mount(params, _session, socket) do
    room = params["room"] || "lobby"

    viewer = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    if connected?(socket) do
      Octoroom.subscribe(room, scope: :room)
      # Outlet stats (queue length, underruns) change without room events.
      :timer.send_interval(1_000, :refresh)
      Phoenix.PubSub.subscribe(Call.PubSub, presence_topic(room))
      {:ok, _} = Call.Presence.track(self(), presence_topic(room), viewer, %{name: nil})
    end

    socket =
      assign(socket,
        room: room,
        me: nil,
        viewer: viewer,
        viewers: viewers(room),
        captions: [],
        recorded: %{},
        recording_dir: nil,
        captions?: Call.Room.captions_available?(),
        assistant?: Call.Room.assistant_available?()
      )

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(
        {:octoroom, _room, {:worker_event, "recorder", {:recorded, seconds, dir}}},
        socket
      ),
      do: {:noreply, assign(socket, recorded: seconds, recording_dir: dir)}

  def handle_info(
        {:octoroom, _room, {:worker_event, "captioner", {:caption, track, line}}},
        socket
      ),
      do: {:noreply, assign(socket, captions: caption(socket.assigns.captions, track, line))}

  # The assistant's events are for the agent lab; they don't change this page.
  def handle_info({:octoroom, _room, {:worker_event, "assistant", _event}}, socket),
    do: {:noreply, socket}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, viewers: viewers(socket.assigns.room))}

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("client", %{"state" => state} = params, socket) do
    me = if state == "joined", do: params["participant_id"]
    {:noreply, socket |> assign(me: me) |> load()}
  end

  def handle_event("toggle_echo", _params, %{assigns: %{me: me}} = socket) when is_binary(me) do
    Octoroom.Room.update_meta(socket.assigns.room, me, &%{&1 | echo: not &1.echo})
    {:noreply, socket}
  end

  def handle_event("toggle_video", _params, %{assigns: %{me: me}} = socket) when is_binary(me) do
    Octoroom.Room.update_meta(socket.assigns.room, me, &%{&1 | video: not &1.video})
    {:noreply, socket}
  end

  def handle_event("flush_echo", _params, %{assigns: %{me: me}} = socket) when is_binary(me) do
    Octoroom.Worker.send(socket.assigns.room, "echo:#{me}", :flush)
    {:noreply, socket}
  end

  def handle_event("crash_echo", _params, %{assigns: %{me: me}} = socket) when is_binary(me) do
    if pid = Octoroom.Worker.whereis(socket.assigns.room, "echo:#{me}"),
      do: Process.exit(pid, :kill)

    {:noreply, socket}
  end

  def handle_event("toggle", %{"assign" => key}, socket)
      when key in ~w(metronome recording captions) do
    key = String.to_existing_atom(key)
    on = get_in(socket.assigns, [:assigns, key]) || false
    Octoroom.Room.assign(socket.assigns.room, key, not on)
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    room = socket.assigns.room

    {participants, workers, outputs, assigns} =
      case Octoroom.Room.state(room) do
        %{} = s -> {s.participants, s.workers, s.outputs, s.assigns}
        {:error, :no_room} -> {[], [], %{}, %{}}
      end

    labels = [
      {"mic", ""},
      {"camera", "’s camera"},
      {"screen", "’s screen"},
      {"screen_audio", "’s screen audio"},
      {"echo", "’s echo"}
    ]

    names =
      for(p <- participants, {track, suffix} <- labels, into: %{}) do
        {"#{p.id}/#{track}", p.meta.name <> suffix}
      end
      |> Map.put("metronome", "metronome")
      |> Map.put("assistant", "the assistant")

    stats = Map.new(outputs, fn {name, _} -> {name, Octoroom.Outlet.stats(room, name)} end)
    me = Enum.find(participants, &(&1.id == socket.assigns.me))
    socket = present_as(socket, me && me.meta.name)

    assign(socket,
      participants: participants,
      workers: workers,
      outputs: outputs,
      stats: stats,
      assigns: assigns,
      names: names,
      my_echo: me != nil and me.meta.echo,
      my_video: me == nil or me.meta.video
    )
  end

  defp name(names, track), do: Map.get(names, track, track)

  defp presence_topic(room), do: "viewers:#{room}"

  # Shown in the call under `name` (nil when not in it). Checked on every
  # load, since after a server restart the page may come back before its
  # participant does.
  defp present_as(socket, name) do
    if connected?(socket) and socket.assigns[:presence_name] != name do
      topic = presence_topic(socket.assigns.room)
      Call.Presence.update(self(), topic, socket.assigns.viewer, %{name: name})
      assign(socket, presence_name: name)
    else
      socket
    end
  end

  # One entry per open page: `nil` for pages not in the call.
  defp viewers(room) do
    for {_id, %{metas: [meta | _]}} <- Call.Presence.list(presence_topic(room)), do: meta.name
  end

  # The newest lines last. A track's line in progress is replaced as Soniox
  # revises it; a done line stays.
  defp caption(captions, track, line) do
    entry = %{track: track, text: line.text, done: line.done}

    captions =
      case Enum.find_index(captions, &(&1.track == track and not &1.done)) do
        nil -> captions ++ [entry]
        i -> List.replace_at(captions, i, entry)
      end

    Enum.take(captions, -8)
  end

  defp input_note(worker, input) do
    dropped = worker.dropped[input] || 0

    cond do
      input not in worker.connected -> " (waiting)"
      dropped > 0 -> " (#{dropped} frames over real time dropped)"
      true -> ""
    end
  end

  # One outlet stat per output, as text: a bare list of integers would
  # render as raw bytes.
  defp stat(stats, outputs, key, unit \\ "") do
    outputs
    |> Enum.flat_map(fn o -> if s = stats[o], do: ["#{Map.fetch!(s, key)}#{unit}"], else: [] end)
    |> Enum.join(", ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Room “{@room}”</h1>
      <p class="sub">
        Browsers talk to Cloudflare Realtime SFU; this LiveView only renders what the room server knows.
      </p>

      <.call_controls room={@room} />

      <div class="controls workers">
        <strong>Video</strong>
        <button phx-click="toggle_video" disabled={@me == nil}>
          {if @my_video, do: "Receive video: on", else: "Receive video: off"}
        </button>
        <span class="hint">Off: the server stops pulling cameras and screens into your session.</span>
      </div>

      <div id="videos" class="videos" phx-update="ignore"></div>

      <div :if={@assistant?} class="controls workers">
        <strong>Assistant</strong>
        <span class={["pill", @assigns[:assistant] && "live"]}>
          {if @assigns[:assistant], do: "on", else: "off"}
        </span>
        <a href={path(@room, "lab")}>Open the agent lab →</a>
        <span class="hint">Pipeline, how it decides to answer, transcript and latency.</span>
      </div>

      <p class="viewers">
        <strong>Here now:</strong>
        {length(@viewers)} page(s) open{case Enum.reject(@viewers, &is_nil/1) do
          [] -> ""
          names -> ", in the call: " <> Enum.join(Enum.sort(names), ", ")
        end}
      </p>

      <div :if={@assigns[:captions]} class="captions" id="captions">
        <p :if={@captions == []} class="empty">Captions are on. Say something…</p>
        <p :for={c <- @captions} class={["line", not c.done && "partial"]}>
          <strong>{name(@names, c.track)}:</strong> {c.text}
        </p>
      </div>

      <table :if={@participants != []}>
        <thead>
          <tr>
            <th>Participant</th><th>Publishes</th><th>Level</th><th>Hears</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @participants} id={"p-#{p.id}"}>
            <td>{p.meta.name}<span :if={p.id == @me} class="you">you</span></td>
            <td>
              <span :if={p.tracks == %{}} class="pill">{p.mic}</span>
              <span
                :for={{source, t} <- Enum.sort(p.tracks)}
                class={["pill", t.status == :live && not t.muted && "live"]}
              >
                {source}{if t.muted, do: " (muted)"}{if t.status != :live, do: " (#{t.status})"}
              </span>
            </td>
            <td>
              <span id={"meter-#{p.id}"} class="meter" phx-update="ignore"><span id={"level-#{p.id}"}></span></span>
            </td>
            <td>
              {case p.hears do
                [] -> "—"
                hears -> hears |> Enum.map(&name(@names, &1)) |> Enum.join(", ")
              end}
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@participants == []} class="empty">Nobody is here yet.</p>

      <details class="tools">
        <summary>Testing tools: echo, metronome, recording, captions, workers</summary>
        <div class="controls workers">
          <button phx-click="toggle_echo" disabled={@me == nil}>
            {if @my_echo, do: "Echo off", else: "Echo on"}
          </button>
          <button class="secondary" phx-click="flush_echo" disabled={not @my_echo}>
            Flush my echo
          </button>
          <button class="secondary" phx-click="crash_echo" disabled={not @my_echo}>
            Crash my echo
          </button>
          <button phx-click="toggle" phx-value-assign="metronome">
            {if @assigns[:metronome], do: "Metronome off", else: "Metronome on"}
          </button>
          <button phx-click="toggle" phx-value-assign="recording">
            {if @assigns[:recording], do: "Stop recording", else: "Record"}
          </button>
          <button :if={@captions?} phx-click="toggle" phx-value-assign="captions">
            {if @assigns[:captions], do: "Captions off", else: "Captions on"}
          </button>
        </div>

        <table :if={@workers != []}>
          <thead>
            <tr>
              <th>Worker</th><th>Hears</th><th>Plays</th><th>Queued</th><th>Sent</th><th>
                Underruns
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={w <- @workers} id={"w-#{w.id}"}>
              <td>
                {w.id |> String.split(":") |> hd()}
                <span class={["pill", w.running && "live"]}>{if w.running,
                  do: "running",
                  else: "restarting"}</span>
              </td>
              <td>
                {case w.inputs do
                  [] ->
                    "—"

                  inputs ->
                    inputs
                    |> Enum.map(&(name(@names, &1) <> input_note(w, &1)))
                    |> Enum.join(", ")
                end}
              </td>
              <td>
                <span :for={o <- w.outputs}>
                  {name(@names, o)}
                  <span class={["pill", get_in(@outputs, [o, :status]) == :live && "live"]}>
                    {get_in(@outputs, [o, :status]) || "—"}
                  </span>
                </span>
              </td>
              <td>{stat(@stats, w.outputs, :queued_ms, " ms")}</td>
              <td>{stat(@stats, w.outputs, :sent)}</td>
              <td>{stat(@stats, w.outputs, :underruns)}</td>
            </tr>
          </tbody>
        </table>

        <div :if={@recorded != %{}} class="recorded">
          <strong>Recorded</strong>
          <span :for={{track, seconds} <- Enum.sort(@recorded)}>
            {name(@names, track)}: {:erlang.float_to_binary(seconds, decimals: 1)} s
          </span>
          <div class="dir">{@recording_dir}</div>
        </div>
      </details>
    </main>
    """
  end
end

defmodule Call.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Call.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {Call.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser
    live "/", Call.CallLive
    live "/r/:room", Call.CallLive
    live "/lab", Call.LabLive
    live "/lab/:room", Call.LabLive
  end
end

defmodule Call.Endpoint do
  use Phoenix.Endpoint, otp_app: :call

  socket "/live", Phoenix.LiveView.Socket
  socket "/socket", Call.UserSocket, websocket: true

  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.mjs phoenix.mjs.map)

  plug Plug.Static,
    at: "/assets/lv",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js phoenix_live_view.esm.js.map)

  plug Plug.Static,
    at: "/assets/octoroom",
    from: {:octoroom, "priv/static"},
    only: ~w(octoroom.mjs)

  plug Plug.Static, at: "/assets", from: {:call, "priv/static"}, only: ~w(app.js)

  plug Call.Router
end
