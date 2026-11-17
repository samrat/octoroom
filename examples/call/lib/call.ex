defmodule Call.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    cf = Application.get_env(:octoroom, :cloudflare, [])

    if cf[:app_id] in [nil, ""] or cf[:app_secret] in [nil, ""],
      do: raise("Set OCTOROOM_CLOUDFLARE_APP_ID and OCTOROOM_CLOUDFLARE_APP_SECRET (see README)")

    children = [{Phoenix.PubSub, name: Call.PubSub}, Call.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: Call.Supervisor)
  end
end

defmodule Call.Room do
  @moduledoc """
  A group call with a mic check: everyone hears everyone, plus

    * a private two-second echo for each participant who turns it on, which
      only they hear;
    * a room-wide metronome, when the room's `:metronome` assign is set;
    * a recorder hearing every mic, when the room's `:recording` assign is set.
  """
  use Octoroom.Room

  @impl true
  def join(%{"name" => name}, _socket) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      name -> {:ok, %{name: String.slice(name, 0, 32), echo: false}}
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

    metronome ++ echoes ++ recorder
  end

  @impl true
  def subscriptions(listener, room) do
    mics = for p <- others(room, listener), do: mic(p)
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
          :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #fff; --card: #f5f5f7; --accent: #f38020; --ok: #2f9e44; }
          @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #98989d; --bg: #111; --card: #1c1c1e; } }
          body { font: 15px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 0; }
          main { max-width: 720px; margin: 0 auto; padding: 24px 16px; }
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
          .warn { background: #f3802022; border-radius: 10px; padding: 10px 12px; margin: 12px 0 0; }
          .recorded { margin-top: 16px; display: flex; flex-wrap: wrap; gap: 12px; }
          .recorded .dir { width: 100%; color: var(--muted); font-size: 12px; font-family: ui-monospace, monospace; }
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

defmodule Call.CallLive do
  use Phoenix.LiveView

  @impl true
  def mount(params, _session, socket) do
    room = params["room"] || "lobby"

    if connected?(socket) do
      Octoroom.subscribe(room)
      # Outlet stats (queue length, underruns) change without room events.
      :timer.send_interval(1_000, :refresh)
    end

    socket =
      assign(socket,
        room: room,
        me: nil,
        recorded: %{},
        recording_dir: nil,
        public_url?: Application.get_env(:octoroom, :public_ws_url) not in [nil, ""]
      )

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(
        {:octoroom, _room, {:worker_event, "recorder", {:recorded, seconds, dir}}},
        socket
      ),
      do: {:noreply, assign(socket, recorded: seconds, recording_dir: dir)}

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

  def handle_event("flush_echo", _params, %{assigns: %{me: me}} = socket) when is_binary(me) do
    Octoroom.Worker.send(socket.assigns.room, "echo:#{me}", :flush)
    {:noreply, socket}
  end

  def handle_event("crash_echo", _params, %{assigns: %{me: me}} = socket) when is_binary(me) do
    if pid = Octoroom.Worker.whereis(socket.assigns.room, "echo:#{me}"),
      do: Process.exit(pid, :kill)

    {:noreply, socket}
  end

  def handle_event("toggle", %{"assign" => key}, socket) when key in ~w(metronome recording) do
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

    names =
      Map.new(participants, &{"#{&1.id}/mic", &1.meta.name})
      |> Map.merge(Map.new(participants, &{"#{&1.id}/echo", "#{&1.meta.name}’s echo"}))
      |> Map.put("metronome", "metronome")

    stats = Map.new(outputs, fn {name, _} -> {name, Octoroom.Outlet.stats(room, name)} end)
    me = Enum.find(participants, &(&1.id == socket.assigns.me))

    assign(socket,
      participants: participants,
      workers: workers,
      outputs: outputs,
      stats: stats,
      assigns: assigns,
      names: names,
      my_echo: me != nil and me.meta.echo
    )
  end

  defp name(names, track), do: Map.get(names, track, track)

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

      <div id="call" class="controls" phx-hook="Call" phx-update="ignore" data-room={@room}>
        <input id="name" type="text" placeholder="Your name" />
        <label><input id="tone" type="checkbox" /> test tone instead of mic</label>
        <button id="join">Join call</button>
        <button id="mute" class="secondary" disabled>Mute</button>
        <button id="leave" class="secondary" disabled>Leave</button>
        <div id="status">Not in the call.</div>
      </div>

      <p :if={not @public_url?} class="warn">
        <code>OCTOROOM_PUBLIC_WS_URL</code>
        isn’t set, so workers run but Cloudflare can’t reach them: nobody will hear them. See the README.
      </p>

      <div class="controls workers">
        <strong>Mic check</strong>
        <button phx-click="toggle_echo" disabled={@me == nil}>
          {if @my_echo, do: "Echo off", else: "Echo on"}
        </button>
        <button class="secondary" phx-click="flush_echo" disabled={not @my_echo}>Flush my echo</button>
        <button class="secondary" phx-click="crash_echo" disabled={not @my_echo}>Crash my echo</button>
        <button phx-click="toggle" phx-value-assign="metronome">
          {if @assigns[:metronome], do: "Metronome off", else: "Metronome on"}
        </button>
        <button phx-click="toggle" phx-value-assign="recording">
          {if @assigns[:recording], do: "Stop recording", else: "Record"}
        </button>
      </div>

      <table :if={@participants != []}>
        <thead>
          <tr>
            <th>Participant</th><th>Mic</th><th>Level</th><th>Hears</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @participants} id={"p-#{p.id}"}>
            <td>{p.meta.name}<span :if={p.id == @me} class="you">you</span></td>
            <td><span class={["pill", p.mic == :live && "live"]}>{p.mic}</span></td>
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

      <table :if={@workers != []}>
        <thead>
          <tr>
            <th>Worker</th><th>Hears</th><th>Plays</th><th>Queued</th><th>Sent</th><th>Underruns</th>
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
                  |> Enum.map(
                    &(name(@names, &1) <> if(&1 in w.connected, do: "", else: " (waiting)"))
                  )
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

  # Serves the sockets Cloudflare dials for workers: set
  # OCTOROOM_PUBLIC_WS_URL to this path's public wss:// URL.
  plug Octoroom.Plug, path: "/octoroom"

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
