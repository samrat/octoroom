defmodule Teleprompter.Store do
  @moduledoc false
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get(room_id) when is_binary(room_id) do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> Agent.get(pid, &Map.get(&1, room_id))
    end
  end

  def get(_), do: nil

  def put(room_id, texts, threshold) when is_binary(room_id) and is_list(texts) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        Agent.update(pid, &Map.put(&1, room_id, %{points: texts, threshold: threshold}))
    end
  end

  def delete(room_id) when is_binary(room_id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.update(pid, &Map.delete(&1, room_id))
    end
  end
end

defmodule Teleprompter.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Teleprompter.PubSub},
      Teleprompter.Store,
      Teleprompter.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Teleprompter.Supervisor)
  end
end

defmodule Teleprompter.Room do
  @moduledoc """
  One speaker (or a whole call) with a silent `Teleprompter.Agent` (`voice: false`)
  listening to every mic and checking off talking points in real time.
  """
  use Octoroom.Room

  import Octoroom.Agent, only: [agent: 3]

  @impl true
  def join(%{"name" => name}, _socket) when is_binary(name) do
    case String.trim(name) do
      "" -> {:ok, %{name: "Speaker"}}
      trimmed -> {:ok, %{name: String.slice(trimmed, 0, 32)}}
    end
  end

  def join(_params, _socket), do: {:ok, %{name: "Speaker"}}

  @impl true
  def workers(%{participants: []}), do: []

  def workers(room) do
    [
      agent("tracker", Teleprompter.Agent,
        name: "Talking Points",
        description: "Silent Clef Flash talking-points tracker",
        hears: Enum.map(room.participants, &mic/1),
        voice: false,
        respond: :always
      )
    ]
  end

  # Data-only subscription so the client can also type test utterances via room.send/2.
  @impl true
  def subscriptions(_listener, _room), do: [track("tracker")]
end

defmodule Teleprompter.RoomChannel do
  use Octoroom.Phoenix.Channel, room: Teleprompter.Room
end

defmodule Teleprompter.UserSocket do
  use Phoenix.Socket

  channel("room:*", Teleprompter.RoomChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end

defmodule Teleprompter.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Octoroom — Talking Points</title>
        <link rel="icon" type="image/svg+xml" href="/assets/logo.svg" />
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
            --accent: #155dfc;
            --accent-hover: #193cb8;
            --accent-bg: #eff6ff;
            --accent-border: #bfdbfe;
            --clef-bg: #fffbeb;
            --clef-border: #fde68a;
            --clef-fg: #b45309;
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
          main { max-width: 860px; margin: 0 auto; padding: 30px 20px 64px; }
          .head {
            display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 12px;
            padding-bottom: 18px; border-bottom: 1px solid var(--border); margin-bottom: 18px;
          }
          .brand-head { display: flex; align-items: center; gap: 10px; }
          .brand {
            display: inline-flex; align-items: center; gap: 9px;
            text-decoration: none; color: var(--fg); font-weight: 700;
            font-size: 20px; letter-spacing: -0.03em;
          }
          .brand:hover { color: var(--accent); }
          .brand-mark { display: block; width: 32px; height: 32px; flex-shrink: 0; }
          .brand-sep { color: var(--border-strong); font-weight: 400; font-size: 20px; user-select: none; }
          h1 { font-size: 19px; font-weight: 600; margin: 0; letter-spacing: -0.02em; color: var(--muted); }
          h2 { font-size: 14px; font-weight: 600; margin: 0; letter-spacing: -0.01em; color: var(--fg); }
          .badges {
            display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; color: var(--faint);
          }
          .pill {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 11px; padding: 2px 8px; border-radius: 6px;
            background: var(--subtle); border: 1px solid var(--border); color: var(--muted);
            display: inline-flex; align-items: center; gap: 5px;
          }
          .pill.live { background: var(--ok-bg); border-color: var(--ok-border); color: var(--ok-fg); }
          .pill.clef { background: var(--clef-bg); border-color: var(--clef-border); color: var(--clef-fg); }
          .pill.accent { background: var(--accent-bg); border-color: var(--accent-border); color: var(--accent-hover); }
          .dot { width: 7px; height: 7px; border-radius: 99px; background: var(--ok); display: inline-block; }
          @keyframes pulseDot {
            0%, 100% { opacity: 1; transform: scale(1); }
            50% { opacity: 0.4; transform: scale(0.85); }
          }
          .dot.pulsing { animation: pulseDot 1.4s ease-in-out infinite; }
          .card {
            background: var(--card); border: 1px solid var(--border); border-radius: 14px;
            padding: 18px 20px; margin-bottom: 16px;
            box-shadow: 0 1px 2px rgba(0,0,0,.03);
          }
          .card-head {
            display: flex; justify-content: space-between; align-items: center; gap: 10px;
            flex-wrap: wrap; margin-bottom: 14px;
          }
          .presets { display: flex; gap: 6px; flex-wrap: wrap; }
          .preset-btn {
            font: inherit; font-size: 12.5px; font-weight: 500; padding: 5px 11px;
            border-radius: 99px; border: 1px solid var(--border); background: var(--card);
            color: var(--muted); cursor: pointer; transition: all .12s;
          }
          .preset-btn:hover { background: var(--subtle); color: var(--fg); }
          .preset-btn.active { background: var(--accent-bg); border-color: var(--accent-border); color: var(--accent-hover); }
          .progress-wrap {
            width: 100%; height: 6px; background: var(--subtle); border-radius: 99px;
            overflow: hidden; margin-bottom: 16px;
          }
          .progress-bar {
            height: 100%; background: var(--ok); border-radius: 99px;
            transition: width .35s ease;
          }
          .points { display: flex; flex-direction: column; gap: 10px; }
          .point {
            display: flex; align-items: flex-start; gap: 12px;
            padding: 14px 16px; border-radius: 12px;
            border: 1.5px solid var(--border); background: var(--card);
            transition: all .2s ease;
          }
          .point.covered {
            background: var(--ok-bg); border-color: var(--ok-border);
          }
          .check-btn {
            width: 26px; height: 26px; border-radius: 99px; flex-shrink: 0; margin-top: 1px;
            border: 2px solid var(--border-strong); background: var(--card);
            color: #fff; display: grid; place-items: center; cursor: pointer;
            padding: 0; font-size: 14px; font-weight: 700; transition: all .15s;
          }
          .check-btn:hover { border-color: var(--accent); background: var(--accent-bg); color: var(--accent); }
          .point.covered .check-btn {
            background: var(--ok); border-color: var(--ok); color: #fff;
          }
          .point-body { flex: 1; min-width: 0; }
          .point-text {
            font-size: 16.5px; font-weight: 550; line-height: 1.4; color: var(--fg);
          }
          .point.covered .point-text {
            color: var(--ok-fg); text-decoration: line-through; text-decoration-color: rgba(4,120,87,.35);
          }
          .point-quote {
            margin-top: 6px; font-size: 13px; color: var(--ok-fg); opacity: .88;
            font-style: italic;
          }
          .point-meter {
            margin-top: 7px; display: flex; align-items: center; gap: 8px;
          }
          .mini-track {
            width: 110px; height: 4px; background: var(--subtle); border-radius: 99px; overflow: hidden;
          }
          .mini-fill { height: 100%; background: var(--accent); border-radius: 99px; transition: width .25s; }
          .point-right { display: flex; align-items: center; gap: 6px; flex-shrink: 0; }
          .del-btn {
            background: transparent; border: 0; color: var(--faint); font-size: 16px;
            cursor: pointer; padding: 2px 6px; border-radius: 6px; line-height: 1;
          }
          .del-btn:hover { background: var(--danger-bg); color: var(--danger-fg); }
          .add-row {
            display: flex; gap: 10px; margin-top: 14px; padding-top: 14px;
            border-top: 1px solid var(--subtle); align-items: center; flex-wrap: wrap;
          }
          .add-form {
            display: flex; gap: 8px; flex: 1; min-width: 240px; align-items: center;
          }
          .editor-box {
            display: flex; flex-direction: column; gap: 10px;
            padding: 14px; border-radius: 12px;
            border: 1.5px solid var(--accent-border); background: var(--accent-bg);
            margin-bottom: 14px;
          }
          .editor-hint {
            font-size: 13px; color: var(--muted);
            display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap;
          }
          textarea.editor-input {
            display: block; width: 100%; min-height: 220px; resize: vertical;
            font: inherit; font-size: 15px; line-height: 1.6;
            padding: 12px 14px; border-radius: 10px;
            border: 1px solid var(--border-strong); background: var(--card); color: var(--fg);
            outline: none;
          }
          textarea.editor-input:focus {
            border-color: var(--accent); box-shadow: 0 0 0 3px rgba(21,93,252,.12);
          }
          .editor-actions {
            display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
          }
          .empty-points {
            padding: 24px 16px; text-align: center; border-radius: 12px;
            border: 1.5px dashed var(--border-strong); background: var(--bg);
            color: var(--muted); font-size: 14px;
            display: flex; flex-direction: column; align-items: center; gap: 10px;
          }
          .threshold-row {
            display: flex; align-items: center; gap: 8px; margin-left: auto;
            font-size: 12px; color: var(--faint); font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          .controls {
            background: var(--card); border: 1px solid var(--border); border-radius: 14px;
            padding: 14px 16px; display: flex; flex-wrap: wrap; gap: 10px; align-items: center;
            margin-bottom: 16px; box-shadow: 0 1px 2px rgba(0,0,0,.03);
          }
          .controls:not(.in-call) .in-call-only { display: none; }
          .controls.in-call .pre-join-only { display: none; }
          .controls .bar-left { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
          .controls .bar-right { display: flex; gap: 8px; align-items: center; margin-left: auto; flex-wrap: wrap; }
          .say-row {
            width: 100%; display: flex; gap: 8px; align-items: center;
            padding-top: 10px; border-top: 1px solid var(--subtle);
          }
          input[type=text] {
            flex: 1; min-width: 180px; font: inherit; font-size: 14px;
            padding: 8px 12px; border-radius: 9px; border: 1px solid var(--border-strong);
            background: var(--card); color: var(--fg); outline: none;
          }
          input[type=text]:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(21,93,252,.12); }
          button {
            font: inherit; font-size: 13.5px; font-weight: 500;
            padding: 8px 14px; border-radius: 9px; border: 1px solid transparent;
            background: var(--accent); color: #fff; cursor: pointer; transition: background .12s;
            display: inline-flex; align-items: center; gap: 6px;
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
          .wave-box {
            flex: 1; min-width: 180px; max-width: 360px; height: 34px;
            display: flex; align-items: center; padding: 0 10px;
            background: var(--subtle); border: 1px solid var(--border); border-radius: 9px;
          }
          .wave-box canvas { width: 100%; height: 24px; display: block; }
          .hearing {
            padding: 10px 14px; border-radius: 10px; margin-bottom: 12px;
            background: var(--accent-bg); border: 1px solid var(--accent-border);
            color: var(--accent-hover); font-size: 14px;
          }
          .log-list { display: flex; flex-direction: column; gap: 8px; max-height: 280px; overflow-y: auto; }
          .log-item {
            padding: 10px 12px; border-radius: 10px; border: 1px solid var(--border);
            background: var(--bg); font-size: 13.5px;
          }
          .log-top {
            display: flex; justify-content: space-between; align-items: center; gap: 8px;
            flex-wrap: wrap; margin-bottom: 4px;
          }
          .scores { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 6px; }
          .score-chip {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 11px; padding: 1px 7px; border-radius: 6px;
            background: var(--card); border: 1px solid var(--border); color: var(--muted);
          }
          .score-chip.hit { background: var(--ok-bg); border-color: var(--ok-border); color: var(--ok-fg); font-weight: 600; }
          .empty { color: var(--faint); font-size: 13.5px; margin: 4px 0; }
          .env-warn {
            background: var(--clef-bg); border: 1px solid var(--clef-border); color: var(--clef-fg);
            border-radius: 10px; padding: 10px 14px; font-size: 13px; margin-bottom: 16px;
          }
        </style>
        <script type="importmap">
          {"imports": {
            "phoenix": "/assets/phoenix/phoenix.mjs",
            "phoenix_live_view": "/assets/lv/phoenix_live_view.esm.js",
            "octoroom": "/assets/octoroom/octoroom.mjs",
            "octoroom_agents": "/assets/octoroom_agents/octoroom_agents.mjs"
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

defmodule Teleprompter.Live do
  use Phoenix.LiveView

  alias Teleprompter.{Agent, Store, Tracker}

  @impl true
  def mount(params, _session, socket) do
    room = params["room"] || "studio"

    if connected?(socket) do
      Octoroom.subscribe(room, scope: :room)
    end

    saved = saved_state(room)
    presets = Agent.presets()

    {:ok,
     assign(socket,
       room: room,
       me: nil,
       local_sfu?: Octoroom.Cloudflare.config().client == Octoroom.Cloudflare.Local,
       missing_keys: missing_keys(),
       presets: presets,
       active_preset: matching_preset(saved.points, presets),
       points: saved.points,
       threshold: saved.threshold,
       history: saved.history,
       partial: nil,
       listening?: false,
       editing?: false,
       draft_text: "",
       editor_key: 0,
       new_point: ""
     )}
  end

  @impl true
  def handle_info(
        {:octoroom, _room, {:worker_event, "tracker", {:agent, {:tracker_state, snap}}}},
        socket
      ) do
    {:noreply,
     assign(socket,
       points: snap.points,
       threshold: snap.threshold,
       history: snap.history,
       partial: nil,
       listening?: true
     )}
  end

  def handle_info(
        {:octoroom, _room,
         {:worker_event, "tracker", {:agent, {:transcription, %{status: "partial", text: t}}}}},
        socket
      ),
      do: {:noreply, assign(socket, partial: t)}

  def handle_info(
        {:octoroom, _room,
         {:worker_event, "tracker", {:agent, {:transcription, %{status: "final"}}}}},
        socket
      ),
      do: {:noreply, assign(socket, partial: nil)}

  def handle_info({:octoroom, _room, {:worker, :added, %{id: "tracker"}}}, socket),
    do: {:noreply, assign(socket, listening?: true)}

  def handle_info({:octoroom, _room, {:worker, :removed, %{id: "tracker"}}}, socket),
    do: {:noreply, assign(socket, listening?: false, partial: nil)}

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("client", %{"state" => state} = params, socket) do
    me = if state == "joined", do: params["participant_id"]
    {:noreply, assign(socket, me: me, listening?: me != nil)}
  end

  def handle_event("select_preset", %{"id" => id}, socket) do
    texts = Agent.preset_points(id)
    {:noreply, apply_new_points(socket, texts, id)}
  end

  def handle_event("new_list", _params, socket) do
    {:noreply,
     assign(socket,
       editing?: true,
       draft_text: "",
       editor_key: socket.assigns.editor_key + 1
     )}
  end

  def handle_event("edit_list", _params, socket) do
    draft = Enum.map_join(socket.assigns.points, "\n", & &1.text)

    {:noreply,
     assign(socket,
       editing?: true,
       draft_text: draft,
       editor_key: socket.assigns.editor_key + 1
     )}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing?: false)}
  end

  def handle_event("clear_editor", _params, socket) do
    {:noreply,
     assign(socket,
       draft_text: "",
       editor_key: socket.assigns.editor_key + 1
     )}
  end

  def handle_event("update_draft", %{"lines" => lines}, socket) do
    {:noreply, assign(socket, draft_text: lines)}
  end

  def handle_event("save_list", %{"lines" => raw}, socket) do
    texts = Tracker.parse_lines(raw)
    {:noreply, apply_new_points(socket, texts, nil)}
  end

  def handle_event("update_new_point", %{"text" => text}, socket) do
    {:noreply, assign(socket, new_point: text)}
  end

  def handle_event("add_point", %{"text" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, assign(socket, new_point: "")}

      trimmed ->
        next_texts = Enum.map(socket.assigns.points, & &1.text) ++ [trimmed]
        Store.put(socket.assigns.room, next_texts, socket.assigns.threshold)

        case Octoroom.Worker.send(
               socket.assigns.room,
               "tracker",
               {:teleprompter, {:add, trimmed}}
             ) do
          :ok ->
            {:noreply, assign(socket, active_preset: nil, new_point: "")}

          {:error, :no_worker} ->
            id = "p#{length(socket.assigns.points) + System.unique_integer([:positive])}"

            point = %{
              id: id,
              text: trimmed,
              covered?: false,
              probability: nil,
              best_probability: 0.0,
              quote: nil,
              covered_at: nil,
              manual?: false
            }

            {:noreply,
             assign(socket,
               active_preset: nil,
               points: socket.assigns.points ++ [point],
               new_point: ""
             )}
        end
    end
  end

  def handle_event("remove_point", %{"id" => id}, socket) do
    points = Enum.reject(socket.assigns.points, &(&1.id == id))
    Store.put(socket.assigns.room, Enum.map(points, & &1.text), socket.assigns.threshold)

    case Octoroom.Worker.send(socket.assigns.room, "tracker", {:teleprompter, {:remove, id}}) do
      :ok ->
        {:noreply, assign(socket, active_preset: nil)}

      {:error, :no_worker} ->
        {:noreply, assign(socket, active_preset: nil, points: points)}
    end
  end

  def handle_event("toggle_point", %{"id" => id}, socket) do
    case Octoroom.Worker.send(socket.assigns.room, "tracker", {:teleprompter, {:toggle, id}}) do
      :ok ->
        {:noreply, socket}

      {:error, :no_worker} ->
        now = System.system_time(:millisecond)

        points =
          Enum.map(socket.assigns.points, fn
            %{id: ^id, covered?: true} = p ->
              %{
                p
                | covered?: false,
                  probability: nil,
                  quote: nil,
                  covered_at: nil,
                  manual?: false
              }

            %{id: ^id, covered?: false} = p ->
              %{
                p
                | covered?: true,
                  probability: 1.0,
                  quote: "Marked manually",
                  covered_at: now,
                  manual?: true
              }

            p ->
              p
          end)

        {:noreply, assign(socket, points: points)}
    end
  end

  def handle_event("reset", _params, socket) do
    case Octoroom.Worker.send(socket.assigns.room, "tracker", {:teleprompter, :reset}) do
      :ok ->
        {:noreply, assign(socket, history: [], partial: nil)}

      {:error, :no_worker} ->
        points =
          Enum.map(socket.assigns.points, fn p ->
            %{
              p
              | covered?: false,
                probability: nil,
                best_probability: 0.0,
                quote: nil,
                covered_at: nil,
                manual?: false
            }
          end)

        {:noreply, assign(socket, points: points, history: [], partial: nil)}
    end
  end

  def handle_event("set_threshold", %{"threshold" => raw}, socket) do
    case Float.parse(raw) do
      {pct_val, _} ->
        threshold = max(0.3, min(0.98, pct_val / 100))
        Store.put(socket.assigns.room, Enum.map(socket.assigns.points, & &1.text), threshold)

        Octoroom.Worker.send(
          socket.assigns.room,
          "tracker",
          {:teleprompter, {:set_threshold, threshold}}
        )

        {:noreply, assign(socket, threshold: threshold)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp apply_new_points(socket, texts, preset_id) do
    points = Tracker.build_points(texts)
    Store.put(socket.assigns.room, texts, socket.assigns.threshold)

    Octoroom.Worker.send(
      socket.assigns.room,
      "tracker",
      {:teleprompter, {:set_points, texts}}
    )

    assign(socket,
      active_preset: preset_id,
      points: points,
      history: [],
      editing?: false
    )
  end

  defp matching_preset(points, presets) do
    texts = Enum.map(points, & &1.text)

    Enum.find_value(presets, fn preset ->
      if preset.points == texts, do: preset.id
    end)
  end

  defp saved_state(room) do
    stored = Store.get(room)

    default = %{
      points: Tracker.build_points((stored && stored.points) || Agent.default_points()),
      threshold: (stored && stored.threshold) || 0.72,
      history: []
    }

    case Octoroom.Worker.saved(room, "tracker") do
      %{tracker: %{} = snap} -> Map.merge(default, snap)
      _ -> default
    end
  end

  defp missing_keys do
    for key <- ~w(OPENROUTER_API_KEY ASSEMBLY_AI_API_KEY),
        System.get_env(key) in [nil, ""],
        do: key
  end

  defp pct(n) when is_number(n), do: "#{round(n * 100)}%"
  defp pct(_), do: "—"

  @impl true
  def render(assigns) do
    total = length(assigns.points)
    covered = Enum.count(assigns.points, & &1.covered?)
    progress = if total == 0, do: 0, else: round(covered / total * 100)
    all_done? = total > 0 and covered == total
    point_labels = Map.new(assigns.points, &{&1.id, &1.text})

    assigns =
      assign(assigns,
        total: total,
        covered: covered,
        progress: progress,
        all_done?: all_done?,
        point_labels: point_labels
      )

    ~H"""
    <main>
      <div class="head">
        <div class="brand-head">
          <a href="/" class="brand">
            <img src="/assets/logo.svg" alt="Octoroom" width="32" height="32" class="brand-mark" />
            <span>Octoroom</span>
          </a>
          <span class="brand-sep" aria-hidden="true">/</span>
          <h1>Talking Points</h1>
        </div>
        <div class="badges">
          <span class="pill">{if @local_sfu?, do: "LOCAL SFU", else: "CLOUDFLARE SFU"}</span>
          <span class="pill clef">CLEF FLASH · SILENT LISTENER</span>
          <span :if={@listening?} class="pill live">
            <span class="dot pulsing"></span> LISTENING
          </span>
        </div>
      </div>

      <div :if={@missing_keys != []} class="env-warn">
        <strong>Missing API keys:</strong>
        set <code>{Enum.join(@missing_keys, ", ")}</code> in <code>examples/teleprompter/.env</code>.
      </div>

      <div
        id="teleprompter-call"
        class={["controls", @me != nil && "in-call"]}
        phx-hook="Teleprompter"
        phx-update="ignore"
        data-room={@room}
      >
        <div class="bar-left pre-join-only">
          <button id="join">Start listening →</button>
          <span class="empty" style="margin:0;">
            Talk freely in any order—Octoroom listens silently and checks off each point.
          </span>
        </div>

        <div class="bar-left in-call-only">
          <button id="mute" class="secondary" disabled>Mute mic</button>
          <div class="wave-box" title="Live microphone level">
            <canvas id="waveform" width="320" height="48"></canvas>
          </div>
        </div>

        <span id="status"></span>

        <div class="bar-right in-call-only">
          <button id="leave" class="danger" disabled>Stop</button>
        </div>

        <form id="say-form" class="say-row in-call-only">
          <input
            id="say-input"
            type="text"
            placeholder="Or type a sentence to test Clef Flash without a microphone…"
            autocomplete="off"
          />
          <button id="say-btn" type="submit" class="secondary">Test utterance</button>
        </form>
      </div>

      <div class="card">
        <div class="card-head">
          <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
            <h2>Your Talking Points</h2>
            <span class={["pill", @all_done? && "live", not @all_done? && "accent"]}>
              {if @all_done?, do: "ALL #{@total} COVERED ✓", else: "#{@covered} / #{@total} COVERED"}
            </span>
          </div>

          <div class="presets">
            <button
              :for={preset <- @presets}
              type="button"
              class={["preset-btn", @active_preset == preset.id and not @editing? && "active"]}
              phx-click="select_preset"
              phx-value-id={preset.id}
            >
              {preset.name}
            </button>
            <button
              type="button"
              class={["preset-btn", (@editing? or @active_preset == nil) && "active"]}
              phx-click="new_list"
            >
              + New list
            </button>
            <button
              :if={@points != []}
              type="button"
              class="secondary"
              phx-click="edit_list"
              style="padding:5px 10px;font-size:12.5px;"
            >
              Edit
            </button>
            <button
              type="button"
              class="secondary"
              phx-click="reset"
              style="padding:5px 10px;font-size:12.5px;"
            >
              Reset
            </button>
          </div>
        </div>

        <form
          :if={@editing?}
          id={"list-editor-#{@editor_key}"}
          phx-submit="save_list"
          phx-change="update_draft"
          class="editor-box"
          style="display:flex;flex-direction:column;gap:10px;padding:14px;border-radius:12px;border:1.5px solid var(--accent-border);background:var(--accent-bg);margin-bottom:14px;"
        >
          <div
            class="editor-hint"
            style="font-size:13px;color:var(--muted);display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;"
          >
            <span><strong>Your talking points</strong> — one per line (bullets or numbers are stripped automatically)</span>
            <span class="pill accent">{length(Tracker.parse_lines(@draft_text))} points</span>
          </div>
          <textarea
            id={"points-textarea-#{@editor_key}"}
            name="lines"
            class="editor-input"
            rows="9"
            autofocus
            style="display:block;width:100%;min-height:220px;resize:vertical;font:inherit;font-size:15px;line-height:1.6;padding:12px 14px;border-radius:10px;border:1px solid var(--border-strong);background:var(--card);color:var(--fg);outline:none;"
            placeholder={"Hook: why this problem matters\nShow the live demo\nShare metrics or customer quote\nClose with next steps"}
          >{@draft_text}</textarea>
          <div
            class="editor-actions"
            style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;"
          >
            <button type="submit">Use this list</button>
            <button type="button" class="secondary" phx-click="clear_editor">Clear</button>
            <button type="button" class="secondary" phx-click="cancel_edit">Cancel</button>
          </div>
        </form>

        <div class="progress-wrap">
          <div class="progress-bar" style={"width: #{@progress}%"}></div>
        </div>

        <div
          :if={@points == [] and not @editing?}
          class="empty-points"
          style="padding:24px 16px;text-align:center;border-radius:12px;border:1.5px dashed var(--border-strong);background:var(--bg);color:var(--muted);font-size:14px;display:flex;flex-direction:column;align-items:center;gap:10px;"
        >
          <div>No talking points yet. Paste a bullet list or add points one by one below.</div>
          <button type="button" phx-click="new_list">Create your list</button>
        </div>

        <div :if={@points != []} class="points">
          <div :for={point <- @points} id={"pt-#{point.id}"} class={["point", point.covered? && "covered"]}>
            <button
              type="button"
              class="check-btn"
              phx-click="toggle_point"
              phx-value-id={point.id}
              title={if point.covered?, do: "Uncheck", else: "Mark covered"}
            >
              {if point.covered?, do: "✓", else: ""}
            </button>

            <div class="point-body">
              <div class="point-text">{point.text}</div>
              <div :if={point.covered? and point.quote} class="point-quote">
                “{point.quote}”
              </div>
              <div
                :if={not point.covered? and (point.best_probability || 0) >= 0.2}
                class="point-meter"
              >
                <div class="mini-track">
                  <div class="mini-fill" style={"width: #{round(point.best_probability * 100)}%"}></div>
                </div>
                <span class="pill" style="font-size:10px;padding:1px 6px;">
                  best {pct(point.best_probability)}
                </span>
              </div>
            </div>

            <div class="point-right">
              <span :if={point.covered?} class="pill live">
                {if point.manual?, do: "manual", else: pct(point.probability)}
              </span>
              <button
                type="button"
                class="del-btn"
                phx-click="remove_point"
                phx-value-id={point.id}
                title="Remove point"
              >
                ×
              </button>
            </div>
          </div>
        </div>

        <div class="add-row">
          <form
            phx-submit="add_point"
            phx-change="update_new_point"
            class="add-form"
            style="display:flex;gap:8px;flex:1;min-width:240px;align-items:center;"
          >
            <input
              type="text"
              name="text"
              value={@new_point}
              placeholder="Add a bullet point…"
              autocomplete="off"
            />
            <button type="submit" class="secondary">Add point</button>
          </form>
          <form phx-change="set_threshold" class="threshold-row">
            <label for="threshold">threshold {pct(@threshold)}</label>
            <input
              id="threshold"
              type="range"
              min="50"
              max="95"
              step="5"
              value={round(@threshold * 100)}
              name="threshold"
              style="width:88px;accent-color:#155dfc;"
            />
          </form>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <h2>Live Hearing &amp; Clef Flash Scores</h2>
          <span class="pill">{length(@history)} utterances</span>
        </div>

        <div :if={@partial} class="hearing">
          <strong>Hearing:</strong> “{@partial}”
        </div>

        <p :if={@history == []} class="empty">
          Hit <strong>Start listening</strong> and talk naturally. As each sentence finishes, Clef Flash scores only the remaining unchecked points—and stops calling the API once all points are covered.
        </p>

        <div class="log-list">
          <div :for={entry <- Enum.reverse(@history)} class="log-item">
            <div class="log-top">
              <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;">
                <span class="pill clef">CLEF FLASH</span>
                <span :if={entry.newly_covered != []} class="pill live">
                  +{length(entry.newly_covered)} checked off
                </span>
              </div>
              <span :if={entry.latency_ms} class="pill">{entry.latency_ms} ms</span>
            </div>
            <div>{entry.text}</div>
            <div :if={map_size(entry.scores) > 0} class="scores">
              <span
                :for={{pid, prob} <- Enum.sort_by(entry.scores, &elem(&1, 1), :desc)}
                class={["score-chip", pid in entry.newly_covered && "hit"]}
                title={Map.get(@point_labels, pid, pid)}
              >
                {pid}: {pct(prob)}
              </span>
            </div>
          </div>
        </div>
      </div>
    </main>
    """
  end
end

defmodule Teleprompter.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Teleprompter.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:put_root_layout, html: {Teleprompter.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)
    live("/", Teleprompter.Live)
    live("/r/:room", Teleprompter.Live)
  end
end

defmodule Teleprompter.Endpoint do
  use Phoenix.Endpoint, otp_app: :teleprompter

  socket("/live", Phoenix.LiveView.Socket)
  socket("/socket", Teleprompter.UserSocket, websocket: true)

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.mjs phoenix.mjs.map)
  )

  plug(Plug.Static,
    at: "/assets/lv",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js phoenix_live_view.esm.js.map)
  )

  plug(Plug.Static,
    at: "/assets/octoroom",
    from: {:octoroom, "priv/static"},
    only: ~w(octoroom.mjs)
  )

  plug(Plug.Static,
    at: "/assets/octoroom_agents",
    from: {:octoroom_agents, "priv/static"},
    only: ~w(octoroom_agents.mjs)
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:teleprompter, "priv/static"},
    only: ~w(app.js logo.svg)
  )

  plug(Teleprompter.Router)
end
