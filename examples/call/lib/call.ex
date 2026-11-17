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
  @moduledoc "A plain group call: everyone hears everyone."
  use Octoroom.Room

  @impl true
  def join(%{"name" => name}, _socket) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      name -> {:ok, %{name: String.slice(name, 0, 32)}}
    end
  end

  def join(_params, _socket), do: {:error, :name_required}
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
    if connected?(socket), do: Octoroom.subscribe(room)
    {:ok, socket |> assign(room: room, me: nil) |> load()}
  end

  @impl true
  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("client", %{"state" => state} = params, socket) do
    me = if state == "joined", do: params["participant_id"]
    {:noreply, assign(socket, me: me)}
  end

  defp load(socket) do
    participants =
      case Octoroom.Room.state(socket.assigns.room) do
        %{participants: ps} -> ps
        {:error, :no_room} -> []
      end

    names = Map.new(participants, &{"#{&1.id}/mic", &1.meta.name})
    assign(socket, participants: participants, names: names)
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
                hears -> hears |> Enum.map(&Map.get(@names, &1, &1)) |> Enum.join(", ")
              end}
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@participants == []} class="empty">Nobody is here yet.</p>
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

  # Serves the sockets Cloudflare dials for workers (milestone 3).
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
