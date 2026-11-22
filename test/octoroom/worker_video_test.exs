defmodule Octoroom.WorkerVideoTest do
  use ExUnit.Case, async: true

  alias Octoroom.{Participant, Reconciler, Room}
  alias Octoroom.Room.Server
  alias Octoroom.Test.{Client, FakeCloudflare, FakePeerMedia}

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9>>

  defmodule AudioOnlyWorker do
    use Octoroom.Worker

    @impl true
    def init(_args, _ctx), do: {:ok, %{}}
  end

  defmodule VisionWorker do
    use Octoroom.Worker,
      video: [
        source: :client,
        fps: 1,
        max_dimension: 768,
        quality: 0.7,
        screen: [fps: 2, max_dimension: 1280, quality: 0.8]
      ]

    @impl true
    def init(%{test: test}, ctx) do
      send(test, {:worker_started, ctx.id, ctx.inputs})
      {:ok, %{test: test, id: ctx.id}}
    end

    @impl true
    def handle_video(input, frame, state) do
      send(state.test, {:worker_video, state.id, input, frame})
      {:ok, state}
    end

    @impl true
    def handle_info({:octoroom, :video_inactive, input}, state) do
      send(state.test, {:worker_video_inactive, state.id, input})
      {:ok, state}
    end

    def handle_info(_msg, state), do: {:ok, state}
  end

  defmodule HighResVisionWorker do
    use Octoroom.Worker,
      video: [source: :client, fps: 2, max_dimension: 1024, quality: 0.9]

    @impl true
    def init(%{test: test}, ctx), do: {:ok, %{test: test, id: ctx.id}}

    @impl true
    def handle_video(input, frame, state) do
      send(state.test, {:worker_video, state.id, input, frame})
      {:ok, state}
    end
  end

  defmodule VisionRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(%{assigns: %{test: nil}}), do: []
    def workers(%{assigns: assigns}) when not is_map_key(assigns, :test), do: []

    def workers(room) do
      test = room.assigns[:test]
      see = room.assigns[:see] || [:camera, :screen]
      extra = room.assigns[:extra_worker] || false

      inputs =
        for p <- room.participants,
            src <- see do
          case src do
            :camera -> camera(p)
            :screen -> screen(p)
            :mic -> mic(p)
          end
        end

      base = [
        worker("vision", VisionWorker, inputs: inputs, data: ["vision"], args: %{test: test})
      ]

      if extra do
        base ++
          [
            worker("hi_res", HighResVisionWorker,
              inputs: Enum.map(room.participants, &camera/1),
              data: ["hi_res"],
              args: %{test: test}
            )
          ]
      else
        base
      end
    end
  end

  setup do
    {:ok, fake} = FakeCloudflare.start_link(self())
    room_id = "vision-#{System.unique_integer([:positive])}"

    opts = [
      cloudflare: FakeCloudflare.config(fake),
      peer_media: FakePeerMedia,
      video_frames: [max_bytes: 1_024, per_second: 10, burst: 2]
    ]

    {:ok, room_id: room_id, cf: fake, opts: opts}
  end

  describe "worker video opt-in and Room.worker/3 validation" do
    test "rejects video inputs for workers that didn't opt into video:" do
      p = %Participant{id: "a"}

      assert_raise ArgumentError, ~r/video/, fn ->
        Room.worker("w", AudioOnlyWorker, inputs: [Room.camera(p)])
      end
    end

    test "allows video inputs for workers with video: [source: :client]" do
      p = %Participant{id: "a"}
      spec = Room.worker("w", VisionWorker, inputs: [Room.mic(p), Room.camera(p), Room.screen(p)])
      assert spec.inputs == ["a/mic", "a/camera", "a/screen"]
    end

    test "validates video options" do
      assert_raise ArgumentError, ~r/source: :client/, fn ->
        Octoroom.Worker.normalize_video!([])
      end

      assert_raise ArgumentError, ~r/fps/, fn ->
        Octoroom.Worker.normalize_video!(source: :client, fps: 0)
      end

      assert_raise ArgumentError, ~r/max_dimension/, fn ->
        Octoroom.Worker.normalize_video!(source: :client, max_dimension: 16)
      end

      assert_raise ArgumentError, ~r/quality/, fn ->
        Octoroom.Worker.normalize_video!(source: :client, quality: 2.0)
      end
    end

    test "reconciler never starts Cloudflare inlets for video inputs" do
      spec = Room.worker("w", VisionWorker, inputs: ["a/mic", "a/camera", "a/screen"])

      actual = %{
        workers: %{"w" => spec},
        outlets: %{},
        inlets: [],
        tracks: %{"a/mic" => :live, "a/camera" => :live, "a/screen" => :live}
      }

      assert Reconciler.diff_workers([spec], actual) == [{:start_inlet, {"w", "a/mic"}}]
    end
  end

  describe "capture directives and frame fan-out" do
    test "pushes capture directives, merges across workers, fans out frames, and notifies on mute/unpublish",
         ctx do
      alice = Client.join(:alice, VisionRoom, ctx.room_id, %{name: "Alice"}, ctx.opts)
      :ok = Room.assign(ctx.room_id, :test, self())

      assert_receive {:client, :alice, {:octoroom_signal, :capture, %{sources: sources}}}, 1_000

      assert sources == %{
               "camera" => %{fps: 1.0, max_dimension: 768, quality: 0.7},
               "screen" => %{fps: 2.0, max_dimension: 1280, quality: 0.8}
             }

      # Adding a second higher-res worker merges max fps/max_dimension/quality for camera.
      :ok = Room.assign(ctx.room_id, :extra_worker, true)

      assert_receive {:client, :alice, {:octoroom_signal, :capture, %{sources: merged}}}, 1_000

      assert merged["camera"] == %{fps: 2.0, max_dimension: 1024, quality: 0.9}
      assert merged["screen"] == %{fps: 2.0, max_dimension: 1280, quality: 0.8}

      # Publishing camera lets frames through; before publishing it's rejected.
      tag = make_ref()
      Server.video_frame(alice.server, alice.id, "camera", %{data: @jpeg}, tag)
      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^tag, {:error, :not_published}}}

      publish_camera(alice)

      # Valid frame fans out to BOTH vision workers from a single upload.
      tag2 = make_ref()

      Server.video_frame(
        alice.server,
        alice.id,
        "camera",
        %{data: @jpeg, mime_type: "image/jpeg", width: 640, height: 360},
        tag2
      )

      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^tag2, {:ok, %{}}}}
      cam_track = "#{alice.id}/camera"

      assert_receive {:worker_video, "vision", ^cam_track,
                      %{
                        data: @jpeg,
                        mime_type: "image/jpeg",
                        width: 640,
                        height: 360,
                        source: "camera"
                      }}

      assert_receive {:worker_video, "hi_res", ^cam_track, %{data: @jpeg, source: "camera"}}

      # Oversized or non-JPEG payloads are rejected.
      tag3 = make_ref()
      big = @jpeg <> :binary.copy(<<0>>, 2_000)
      Server.video_frame(alice.server, alice.id, "camera", %{data: big}, tag3)
      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^tag3, {:error, :too_large}}}

      tag4 = make_ref()
      Server.video_frame(alice.server, alice.id, "camera", %{data: "not-a-jpeg"}, tag4)
      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^tag4, {:error, :bad_payload}}}

      # Rate limiting enforces burst (2 in setup: 1 used above, 1 more allowed, 3rd rejected).
      t_ok = make_ref()
      Server.video_frame(alice.server, alice.id, "camera", %{data: @jpeg}, t_ok)
      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^t_ok, {:ok, %{}}}}

      t_rl = make_ref()
      Server.video_frame(alice.server, alice.id, "camera", %{data: @jpeg}, t_rl)
      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^t_rl, {:error, :rate_limited}}}

      # Muting camera notifies workers and blocks frames until unmuted.
      Server.mute(alice.server, alice.id, "camera", true)
      assert_receive {:worker_video_inactive, "vision", ^cam_track}

      t_muted = make_ref()
      Server.video_frame(alice.server, alice.id, "camera", %{data: @jpeg}, t_muted)
      assert_receive {:client, :alice, {:octoroom_signal, :reply, ^t_muted, {:error, :muted}}}

      # Removing extra_worker lowers camera params back to VisionWorker's, then
      # narrowing see: to [:screen] drops camera completely.
      :ok = Room.assign(ctx.room_id, :extra_worker, false)

      assert_receive {:client, :alice,
                      {:octoroom_signal, :capture,
                       %{sources: %{"camera" => %{max_dimension: 768}, "screen" => _}}}},
                     1_000

      :ok = Room.assign(ctx.room_id, :see, [:screen])

      assert_receive {:client, :alice, {:octoroom_signal, :capture, %{sources: updated}}}, 1_000
      assert Map.keys(updated) == ["screen"]
    end

    test "channel validates base64 JPEG and forwards video_frame", ctx do
      alice = Client.join(:alice, VisionRoom, ctx.room_id, %{name: "Alice"}, ctx.opts)
      :ok = Room.assign(ctx.room_id, :test, self())
      assert_receive {:worker_started, "vision", _}
      publish_camera(alice)

      socket = %Phoenix.Socket{
        joined: true,
        ref: "1",
        join_ref: "1",
        topic: "room:#{ctx.room_id}",
        transport_pid: self(),
        serializer: Phoenix.Socket.V2.JSONSerializer,
        assigns: %{
          octoroom: %{server: alice.server, participant_id: alice.id, room_id: ctx.room_id}
        }
      }

      assert {:reply, {:error, %{reason: "bad_payload"}}, _} =
               Octoroom.Phoenix.Channel.__handle_in__(
                 "video_frame",
                 %{"source" => "camera", "data" => Base.encode64("nope")},
                 socket
               )

      assert {:reply, {:error, %{reason: "bad_payload"}}, _} =
               Octoroom.Phoenix.Channel.__handle_in__(
                 "video_frame",
                 %{
                   "source" => "camera",
                   "mime_type" => "image/png",
                   "data" => Base.encode64(@jpeg)
                 },
                 socket
               )

      assert {:reply, {:error, %{reason: "too_large"}}, _} =
               Octoroom.Phoenix.Channel.__handle_in__(
                 "video_frame",
                 %{
                   "source" => "camera",
                   "data" => Base.encode64(:binary.copy(<<0xFF>>, 600_000))
                 },
                 socket
               )

      assert {:noreply, _} =
               Octoroom.Phoenix.Channel.__handle_in__(
                 "video_frame",
                 %{
                   "source" => "camera",
                   "mime_type" => "image/jpeg",
                   "width" => 320,
                   "height" => 240,
                   "data" => Base.encode64(@jpeg)
                 },
                 socket
               )

      cam_track = "#{alice.id}/camera"

      assert_receive {:worker_video, "vision", ^cam_track,
                      %{data: @jpeg, width: 320, height: 240}}
    end
  end

  defp publish_camera(client) do
    tag = make_ref()
    Server.publish(client.server, client.id, "offer", %{"mic" => "0", "camera" => "1"}, tag)
    assert_receive {:client, _, {:octoroom_signal, :reply, ^tag, {:ok, %{sdp: _}}}}, 1_000
    Server.connected(client.server, client.id)
  end
end
