defmodule Call.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    cf = Application.get_env(:octoroom, :cloudflare, [])

    if cf[:client] in [nil, Octoroom.Cloudflare.HTTP] and
         (cf[:app_id] in [nil, ""] or cf[:app_secret] in [nil, ""]),
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
      (needs `SONIOX_API_KEY`).
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

    metronome ++ echoes ++ recorder ++ captioner
  end

  def captions_available?, do: Application.get_env(:call, :soniox_api_key) not in [nil, ""]

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
    metronome = if room.assigns[:metronome], do: [track("metronome")], else: []
    mics ++ own_echo ++ metronome
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
          :root {
            color-scheme: light;
            --bg: #fafaf9;
            --card: #ffffff;
            --subtle: #f5f5f4;
            --fg: #1c1917;
            --muted: #57534e;
            --faint: #78716c;
            --border: #e7e5e4;
            --border-strong: #d6d3d1;
            --accent: #ea580c;
            --accent-hover: #c2410c;
            --ok-bg: #ecfdf5;
            --ok-border: #a7f3d0;
            --ok-fg: #047857;
            --ok: #16a34a;
            --danger-bg: #fef2f2;
            --danger-border: #fecaca;
            --danger-fg: #b91c1c;
          }
          * { box-sizing: border-box; }
          body {
            font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased;
            color: var(--fg);
            background: var(--bg);
            margin: 0;
          }
          main { max-width: 860px; margin: 0 auto; padding: 36px 20px 64px; }
          .head {
            display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 12px;
            padding-bottom: 18px; border-bottom: 1px solid var(--border); margin-bottom: 24px;
          }
          h1 { font-size: 22px; font-weight: 650; margin: 0; letter-spacing: -0.025em; }
          .badges {
            display: flex; gap: 8px; align-items: center;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; color: var(--faint);
          }
          .sub { color: var(--muted); margin: 0 0 20px; font-size: 14px; }
          .controls {
            background: var(--card); border: 1px solid var(--border); border-radius: 12px;
            padding: 12px 14px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
          }
          .controls.card:not(.in-call) {
            max-width: 480px; margin: 44px auto 0; padding: 28px; border-radius: 16px;
            display: block; box-shadow: 0 1px 2px rgba(0,0,0,.04), 0 12px 32px rgba(0,0,0,.04);
          }
          .controls:not(.in-call) .in-call-only { display: none; }
          .controls.in-call .pre-join-only { display: none; }
          .controls:not(.has-camera) .camera-only { display: none; }
          .pre-join-copy h2 { margin: 0 0 6px; font-size: 18px; font-weight: 600; letter-spacing: -0.015em; }
          .pre-join-copy p { margin: 0 0 18px; font-size: 14px; color: var(--muted); }
          .field-row { display: flex; gap: 8px; align-items: center; flex: 1; }
          .controls.in-call .bar-left { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
          .controls.in-call .bar-right { display: flex; gap: 10px; align-items: center; margin-left: auto; flex-wrap: wrap; }
          .join-checks {
            display: flex; flex-wrap: wrap; gap: 14px; margin-top: 16px; padding-top: 14px;
            border-top: 1px solid var(--subtle); font-size: 13px; color: var(--muted); width: 100%;
          }
          .join-checks label { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; }
          input[type=text] {
            flex: 1; min-width: 160px; font: inherit; font-size: 14px;
            padding: 9px 12px; border-radius: 9px; border: 1px solid var(--border-strong);
            background: var(--card); color: var(--fg); outline: none;
          }
          input[type=text]:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(234,88,12,.12); }
          button {
            font: inherit; font-size: 13.5px; font-weight: 500;
            padding: 8px 14px; border-radius: 9px; border: 1px solid transparent;
            background: var(--accent); color: #fff; cursor: pointer; transition: background .12s;
          }
          button:hover:not(:disabled) { background: var(--accent-hover); }
          button:disabled { opacity: .45; cursor: default; }
          button.secondary { background: var(--card); border-color: var(--border); color: var(--fg); }
          button.secondary:hover:not(:disabled) { background: var(--subtle); }
          button.danger { background: var(--danger-bg); border-color: var(--danger-border); color: var(--danger-fg); }
          button.danger:hover:not(:disabled) { background: #fee2e2; }
          #status {
            color: var(--faint); font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          #status:empty { display: none; }
          .controls:not(.in-call) #status { display: block; margin-top: 12px; }
          .controls.in-call #status { margin-left: auto; }
          .controls.in-call .bar-right { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
          .controls.in-call #status:empty + .bar-right { margin-left: auto; }
          .roster { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 14px; }
          .member {
            display: inline-flex; align-items: center; gap: 8px;
            background: var(--card); border: 1px solid var(--border);
            padding: 6px 12px; border-radius: 99px; font-size: 13px;
          }
          .member .name { font-weight: 600; }
          table { width: 100%; border-collapse: collapse; margin-top: 14px; font-size: 12.5px; }
          th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--subtle); vertical-align: top; }
          th {
            font-size: 11px; text-transform: uppercase; letter-spacing: .04em;
            color: var(--faint); font-weight: 600; border-bottom-color: var(--border);
          }
          td { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .you { color: var(--accent); font-size: 11.5px; font-weight: 600; }
          .pill {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 11.5px; padding: 2px 8px; border-radius: 6px;
            background: var(--subtle); border: 1px solid var(--border); color: var(--muted);
          }
          .pill.live { background: var(--ok-bg); border-color: var(--ok-border); color: var(--ok-fg); }
          .meter { display: inline-block; width: 42px; height: 5px; background: var(--border); border-radius: 99px; overflow: hidden; vertical-align: middle; }
          .meter > span { display: block; height: 100%; width: 0; background: var(--ok); transition: width .12s; }
          .empty { color: var(--faint); margin-top: 16px; font-size: 14px; }
          .workers { margin-top: 10px; }
          .recorded { margin-top: 12px; display: flex; flex-wrap: wrap; gap: 10px; font-size: 12.5px; }
          .recorded .dir { width: 100%; color: var(--faint); font-size: 12px; font-family: ui-monospace, monospace; }
          .viewers { color: var(--faint); font-size: 12.5px; margin: 12px 0 0; }
          .captions {
            background: var(--card); border: 1px solid var(--border);
            border-radius: 12px; padding: 12px 16px; margin-top: 16px;
          }
          .captions .line { margin: 4px 0; }
          .captions .partial { color: var(--faint); }
          .hint { color: var(--faint); font-size: 13px; }
          .tools {
            margin-top: 22px; background: var(--card); border: 1px solid var(--border);
            border-radius: 12px; padding: 14px 16px;
          }
          .tools-toggle {
            width: 100%; display: flex; align-items: center; justify-content: space-between;
            background: transparent; border: 0; padding: 0; color: var(--muted);
            font-size: 13px; font-weight: 500; text-align: left; cursor: pointer;
          }
          .tools-toggle:hover:not(:disabled) { background: transparent; color: var(--fg); }
          .tools-body { margin-top: 12px; }
          .tool-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
          .tool-row button { padding: 6px 12px; font-size: 13px; }
          .tool-row button.active { background: var(--fg); border-color: var(--fg); color: #fff; }
          a { color: var(--accent); text-decoration: none; font-weight: 500; }
          a:hover { text-decoration: underline; }
          .videos { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; margin-bottom: 16px; }
          .videos:empty { display: none; }
          .tile {
            position: relative; aspect-ratio: 16 / 9; background: #1c1917; border-radius: 14px;
            overflow: hidden; border: 1px solid var(--border); box-shadow: 0 4px 16px rgba(0,0,0,.06);
          }
          .tile video { width: 100%; height: 100%; object-fit: cover; display: block; }
          .tile.audio-only video { display: none; }
          .tile .avatar-stage {
            position: absolute; inset: 0; display: none; place-items: center;
            background: radial-gradient(circle at 30% 25%, #2c3e50 0%, #141820 70%);
          }
          .tile:nth-child(2n) .avatar-stage {
            background: radial-gradient(circle at 70% 30%, #3b2f4a 0%, #17141f 70%);
          }
          .tile.audio-only .avatar-stage { display: grid; }
          .tile .avatar-circle {
            width: 68px; height: 68px; border-radius: 999px; display: grid; place-items: center;
            font-weight: 600; font-size: 24px; color: #fff;
            background: linear-gradient(135deg, #f38020, #e11d48);
            box-shadow: 0 8px 28px rgba(0,0,0,.35);
          }
          .tile:nth-child(2n) .avatar-circle { background: linear-gradient(135deg, #6366f1, #0ea5e9); }
          .tile.screen video { object-fit: contain; }
          .tile.mirror video { transform: scaleX(-1); }
          .tile .label {
            position: absolute; left: 10px; bottom: 10px; font-size: 12.5px; font-weight: 500;
            color: var(--fg); background: rgba(255,255,255,.92); backdrop-filter: blur(8px);
            padding: 3px 9px; border-radius: 7px;
          }
          .tile .paused { position: absolute; inset: 0; display: none; place-items: center; color: #f5f5f4; background: #292524; font-size: 13px; }
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
  attr :card, :boolean, default: false
  attr :local_sfu?, :boolean, default: false

  def call_controls(assigns) do
    ~H"""
    <div
      id="call"
      class={["controls", @card && "card"]}
      phx-hook="Call"
      phx-update="ignore"
      data-room={@room}
    >
      <div :if={@card} class="pre-join-copy pre-join-only">
        <h2>Join the call</h2>
        <p>
          {if @local_sfu?,
            do:
              "Runs locally over WebRTC with zero API keys. Open another tab at this URL to talk between tabs.",
            else:
              "WebRTC audio and video routed by your Phoenix room server. Open another tab to test."}
        </p>
      </div>

      <div class="field-row pre-join-only">
        <input id="name" type="text" placeholder="Your name" />
        <button id="join">Join call →</button>
      </div>

      <div class="join-checks pre-join-only">
        <label><input id="join-camera" type="checkbox" /> Join with camera</label>
        <label><input id="tone" type="checkbox" /> Test tone</label>
        <label><input id="pattern" type="checkbox" /> Test pattern</label>
      </div>

      <div class="bar-left in-call-only">
        <button id="mute" class="secondary" disabled>Mute</button>
        <button id="camera" class="secondary" disabled>Camera on</button>
        <button id="pause" class="secondary camera-only" disabled>Pause video</button>
        <button id="screen" class="secondary" disabled>Share screen</button>
      </div>

      <span id="status"></span>

      <div class="bar-right in-call-only">
        <button id="leave" class="danger" disabled>Leave</button>
      </div>
    </div>
    """
  end

  @doc "The page for `room`: `path(\"lobby\")` is `/`, others `/r/<room>`."
  def path("lobby"), do: "/"
  def path(room), do: "/r/#{room}"
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
        local_sfu?: Octoroom.Cloudflare.config().client == Octoroom.Cloudflare.Local,
        tools_open: false
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

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, viewers: viewers(socket.assigns.room))}

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("client", %{"state" => state} = params, socket) do
    me = if state == "joined", do: params["participant_id"]
    {:noreply, socket |> assign(me: me) |> load()}
  end

  def handle_event("toggle_tools", _params, socket),
    do: {:noreply, assign(socket, tools_open: not socket.assigns.tools_open)}

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
      <div class="head">
        <h1>Room “{@room}”</h1>
        <div class="badges">
          <span class="pill">{if @local_sfu?, do: "LOCAL SFU", else: "CLOUDFLARE SFU"}</span>
          <span :if={@participants != []} class="pill live">
            {length(@participants)} IN CALL
          </span>
        </div>
      </div>

      <div id="videos" class="videos" phx-update="ignore"></div>

      <.call_controls room={@room} card={true} local_sfu?={@local_sfu?} />

      <div :if={@participants != []} class="roster">
        <div :for={p <- @participants} id={"p-#{p.id}"} class="member">
          <span class="name">{p.meta.name}</span>
          <span :if={p.id == @me} class="you">you</span>
          <span id={"meter-#{p.id}"} class="meter" phx-update="ignore">
            <span id={"level-#{p.id}"}></span>
          </span>
          <span
            :for={{source, t} <- Enum.sort(p.tracks)}
            class={["pill", t.status == :live && not t.muted && "live"]}
          >
            {source}{if t.muted, do: " muted"}
          </span>
        </div>
      </div>

      <div :if={@assigns[:captions]} class="captions" id="captions">
        <p :if={@captions == []} class="empty">Captions are on. Say something…</p>
        <p :for={c <- @captions} class={["line", not c.done && "partial"]}>
          <strong>{name(@names, c.track)}:</strong> {c.text}
        </p>
      </div>

      <div class="tools">
        <button
          type="button"
          class="tools-toggle"
          phx-click="toggle_tools"
          aria-expanded={@tools_open}
        >
          <span>Room inspector &amp; server workers</span>
          <span>{if @tools_open, do: "▾", else: "▸"}</span>
        </button>

        <div :if={@tools_open} class="tools-body">
          <div class="tool-row">
            <button
              class={["secondary", @my_echo && "active"]}
              phx-click="toggle_echo"
              disabled={@me == nil}
            >
              {if @my_echo, do: "Echo: on", else: "Echo: off"}
            </button>
            <button class="secondary" phx-click="flush_echo" disabled={not @my_echo}>
              Flush echo
            </button>
            <button class="secondary" phx-click="crash_echo" disabled={not @my_echo}>
              Crash echo
            </button>
            <button
              class={["secondary", @assigns[:metronome] && "active"]}
              phx-click="toggle"
              phx-value-assign="metronome"
            >
              {if @assigns[:metronome], do: "Metronome: on", else: "Metronome: off"}
            </button>
            <button
              class={["secondary", @assigns[:recording] && "active"]}
              phx-click="toggle"
              phx-value-assign="recording"
            >
              {if @assigns[:recording], do: "Stop recording", else: "Record WAV"}
            </button>
            <button
              :if={@captions?}
              class={["secondary", @assigns[:captions] && "active"]}
              phx-click="toggle"
              phx-value-assign="captions"
            >
              {if @assigns[:captions], do: "Captions: on", else: "Captions: off"}
            </button>
            <button
              class={["secondary", @my_video && "active"]}
              phx-click="toggle_video"
              disabled={@me == nil}
            >
              {if @my_video, do: "Receive video: on", else: "Receive video: off"}
            </button>
          </div>

          <p class="viewers">
            <strong>Here now:</strong>
            {length(@viewers)} page(s) open{case Enum.reject(@viewers, &is_nil/1) do
              [] -> ""
              names -> ", in the call: " <> Enum.join(Enum.sort(names), ", ")
            end}
          </p>

          <table :if={@participants != []}>
            <thead>
              <tr>
                <th>Participant</th><th>Publishes</th><th>Hears</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @participants} id={"inspect-p-#{p.id}"}>
                <td>{p.meta.name}<span :if={p.id == @me} class="you"> you</span></td>
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
                  {case p.hears do
                    [] -> "—"
                    hears -> hears |> Enum.map(&name(@names, &1)) |> Enum.join(", ")
                  end}
                </td>
              </tr>
            </tbody>
          </table>

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
        </div>
      </div>
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
