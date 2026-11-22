defmodule VisionWeb.VisionLive do
  @moduledoc """
  One person talking to a vision-capable voice agent, with camera and screen
  sharing. Switch between the cascaded vision LLM pipeline and Gemini Live,
  and inspect the latest JPEG frame the agent received.
  """
  use VisionWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    room = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    if connected?(socket), do: Octoroom.subscribe(room, scope: :room)

    {:ok,
     assign(socket,
       room: room,
       mode: :cascaded,
       frames: %{},
       frame_count: 0
     )}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket)
      when mode in ["cascaded", "gemini_live"] do
    mode_atom = String.to_existing_atom(mode)
    _ = Octoroom.Room.assign(socket.assigns.room, :mode, mode_atom)
    {:noreply, assign(socket, mode: mode_atom)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:octoroom, _room, {:worker_event, "assistant", {:agent, {:video_frame, frame}}}},
        socket
      ) do
    preview = %{
      source: frame.source,
      track_source: frame.track_source || "video",
      width: frame.width,
      height: frame.height,
      kb: Float.round(frame.bytes / 1024, 1),
      data_uri: "data:#{frame.mime_type};base64,#{Base.encode64(frame.data)}"
    }

    {:noreply,
     assign(socket,
       frames: Map.put(socket.assigns.frames, frame.source, preview),
       frame_count: socket.assigns.frame_count + 1
     )}
  end

  def handle_info(
        {:octoroom, _room, {:worker_event, "assistant", {:agent, {:video_inactive, %{source: src}}}}},
        socket
      ) do
    {:noreply, assign(socket, frames: Map.delete(socket.assigns.frames, src))}
  end

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Talk to a vision agent
        <:subtitle>
          Join, turn on your camera or share your screen, and ask the agent what it sees.
          Use headphones so the agent's voice doesn't leak back into your mic.
        </:subtitle>
      </.header>

      <div class="flex flex-wrap items-center gap-2 mb-4">
        <span class="text-sm text-base-content/60">Pipeline:</span>
        <button
          type="button"
          phx-click="set_mode"
          phx-value-mode="cascaded"
          class={["btn btn-sm", if(@mode == :cascaded, do: "btn-primary", else: "btn-ghost")]}
        >
          Cascaded (Gemini Flash)
        </button>
        <button
          type="button"
          phx-click="set_mode"
          phx-value-mode="gemini_live"
          class={["btn btn-sm", if(@mode == :gemini_live, do: "btn-primary", else: "btn-ghost")]}
        >
          Gemini Live
        </button>
      </div>

      <div id="vision" phx-hook="Vision" data-room={@room} data-mode={@mode} class="space-y-4">
        <div id="controls" phx-update="ignore" class="flex flex-wrap items-center gap-2">
          <.button id="join" variant="primary">Join</.button>
          <.button id="leave" disabled>Leave</.button>
          <.button id="mute" disabled>Mute</.button>
          <.button id="camera" disabled>Camera on</.button>
          <.button id="screen" disabled>Share screen</.button>
          <.button id="pause-vision" disabled>Pause AI vision</.button>
          <span id="state" class="badge badge-ghost">not joined</span>
          <span id="capture-badge" class="badge badge-ghost">AI sees: nothing</span>
          <p id="status" class="w-full text-sm text-base-content/60"></p>
        </div>

        <div id="local-preview" phx-update="ignore" class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div id="camera-card" class="hidden rounded-box border border-base-300 overflow-hidden bg-base-200">
            <div class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Your camera
            </div>
            <video id="camera-video" autoplay muted playsinline class="w-full aspect-video object-cover"></video>
          </div>
          <div id="screen-card" class="hidden rounded-box border border-base-300 overflow-hidden bg-base-200">
            <div class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Your screen
            </div>
            <video id="screen-video" autoplay muted playsinline class="w-full aspect-video object-contain bg-black"></video>
          </div>
        </div>

        <form id="say" phx-update="ignore" class="join w-full">
          <input
            id="text"
            type="text"
            placeholder="Ask what it sees, or speak aloud…"
            autocomplete="off"
            class="input join-item flex-1"
            disabled
          />
          <button type="submit" class="btn join-item" disabled>Send</button>
        </form>

        <section>
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
            Transcript
          </h2>
          <div id="transcript" phx-update="ignore" class="space-y-2"></div>
        </section>
      </div>

      <section id="agent-sight" class="space-y-2 mt-6">
        <div class="flex items-center justify-between">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            What the agent last received
          </h2>
          <span class="text-xs font-mono text-base-content/60">{@frame_count} frames</span>
        </div>

        <p :if={map_size(@frames) == 0} class="text-sm text-base-content/60">
          Turn on your camera or share your screen after joining to stream snapshots to the agent.
        </p>

        <div :if={map_size(@frames) > 0} class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div
            :for={{_key, f} <- Enum.sort(@frames)}
            class="rounded-box border border-base-300 overflow-hidden bg-base-200"
          >
            <div class="flex items-center justify-between px-3 py-1.5 text-xs text-base-content/70">
              <span class="font-semibold uppercase tracking-wide">{f.track_source}</span>
              <span class="font-mono">
                {if f.width && f.height, do: "#{f.width}x#{f.height} · ", else: ""}{f.kb} KB
              </span>
            </div>
            <img src={f.data_uri} alt={"Latest #{f.track_source} frame"} class="w-full aspect-video object-contain bg-black" />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
