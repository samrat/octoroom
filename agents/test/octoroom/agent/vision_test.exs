defmodule Octoroom.Agent.VisionTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.GeminiLive.Protocol, as: GeminiProtocol
  alias Octoroom.Agent.Pipeline.{Core, Spec}
  alias Octoroom.Agent.Processors.{Context, GeminiLive, OpenAILive}
  alias Octoroom.Participant
  alias ReqLLM.Message.ContentPart

  @jpeg_a <<0xFF, 0xD8, 0xFF, 0xE0, "A", 0xFF, 0xD9>>
  @jpeg_b <<0xFF, 0xD8, 0xFF, 0xE0, "B", 0xFF, 0xD9>>
  @jpeg_screen <<0xFF, 0xD8, 0xFF, 0xE0, "S", 0xFF, 0xD9>>

  defmodule VisionAgent do
    use Octoroom.Agent

    @impl true
    def pipeline(_ctx) do
      Spec.default(
        vad: [analyzer: :none],
        stt: "soniox:stt-rt-v6",
        llm: [request: fn _opts, _emit -> {:ok, %{text: "I see it."}} end],
        tts: "openai:gpt-4o-mini-tts"
      )
    end
  end

  describe "Octoroom.Agent.agent/3 sees:" do
    test "merges sees: into worker inputs alongside hears:" do
      p = %Participant{id: "alice"}

      spec =
        Octoroom.Agent.agent("assistant", VisionAgent,
          hears: [Octoroom.Room.mic(p)],
          sees: [Octoroom.Room.camera(p), Octoroom.Room.screen(p)]
        )

      assert spec.inputs == ["alice/mic", "alice/camera", "alice/screen"]
      assert %{source: :client} = Octoroom.Worker.video_config(spec.module)
    end
  end

  describe "Processors.Context vision attachment" do
    test "attaches labeled fresh frames to the live turn only and strips them from history" do
      clock = :atomics.new(1, signed: true)
      :atomics.put(clock, 1, 1_000)

      spec =
        Spec.processor(:context, Context,
          instructions: "Be helpful.",
          frame_ttl_ms: 5_000,
          max_frames: 2,
          clock: fn -> :atomics.get(clock, 1) end
        )

      {:ok, core} = Core.new(spec, %{owner: self()})

      # Bob's camera, Alice's camera, and Carol's screen arrive.
      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_b,
          source: "bob/camera",
          track_source: "camera",
          speaker: "Bob"
        })

      :atomics.put(clock, 1, 1_100)

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_a,
          source: "alice/camera",
          track_source: "camera",
          speaker: "Alice"
        })

      :atomics.put(clock, 1, 1_200)

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_screen,
          source: "carol/screen",
          track_source: "screen",
          speaker: "Carol"
        })

      # Alice asks a question: max_frames=2 should pick Carol's screen first, then Alice's camera.
      {commands, core} =
        Core.push(core, %Frames.Transcription{
          turn_id: 1,
          text: "What is on screen?",
          source: "alice/mic",
          speaker: "Alice",
          respond: true
        })

      assert [{:output, %Frames.LLMContext{messages: [system, user]}}] = commands
      assert system == %{role: "system", content: "Be helpful."}
      assert user.role == "user"

      assert [
               %ContentPart{type: :text, text: "[Carol's screen]"},
               %ContentPart{type: :image, data: @jpeg_screen, media_type: "image/jpeg"},
               %ContentPart{type: :text, text: "[Alice's camera]"},
               %ContentPart{type: :image, data: @jpeg_a, media_type: "image/jpeg"},
               %ContentPart{type: :text, text: "[Alice] What is on screen?"}
             ] = user.content

      # Saved history must NOT retain image bytes.
      state = Core.stage_state(core, :context)

      assert [%{role: "user", content: "[Alice] What is on screen?"}, %{reply_pending: true}] =
               state.history

      # Complete reply and advance clock past TTL; next turn has no stale frames.
      {_, core} = Core.push(core, %Frames.AssistantMessage{text: "A chart."}, :upstream)
      :atomics.put(clock, 1, 10_000)

      {commands2, _core} =
        Core.push(core, %Frames.Transcription{
          turn_id: 2,
          text: "Thanks!",
          source: "alice/mic",
          speaker: "Alice",
          respond: true
        })

      assert [{:output, %Frames.LLMContext{messages: [_sys, prev_u, _prev_a, next_u]}}] =
               commands2

      assert prev_u == %{role: "user", content: "[Alice] What is on screen?"}
      assert next_u == %{role: "user", content: "[Alice] Thanks!"}
    end

    test "clears cached frame on VideoInactive" do
      spec = Spec.processor(:context, Context)
      {:ok, core} = Core.new(spec, %{})

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_a,
          source: "alice/camera",
          track_source: "camera",
          speaker: "Alice"
        })

      {_, core} = Core.push(core, %Frames.VideoInactive{source: "alice/camera"})

      {commands, _core} =
        Core.push(core, %Frames.Transcription{
          turn_id: 1,
          text: "Hello",
          source: "alice/mic",
          speaker: "Alice",
          respond: true
        })

      assert [
               {:output,
                %Frames.LLMContext{messages: [%{role: "user", content: "[Alice] Hello"}]}}
             ] =
               commands
    end

    test "attaches frames alongside UserAudio for half-cascaded turns" do
      spec = Spec.processor(:context, Context)
      {:ok, core} = Core.new(spec, %{})

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_screen,
          source: "alice/screen",
          track_source: "screen",
          speaker: "Alice"
        })

      {commands, _core} =
        Core.push(core, %Frames.UserAudio{
          turn_id: 1,
          audio: <<0, 1, 2, 3>>,
          source: "alice/mic",
          speaker: "Alice",
          respond: true
        })

      assert [{:output, %Frames.LLMContext{messages: [%{role: "user", content: parts}]}}] =
               commands

      assert Enum.any?(parts, &match?(%ContentPart{type: :image, data: @jpeg_screen}, &1))
      assert Enum.any?(parts, &match?(%ContentPart{type: :file, media_type: "audio/wav"}, &1))
    end
  end

  describe "Gemini Live vision streaming" do
    test "encodes video_input_frame in Gemini realtimeInput wire format" do
      assert %{
               realtimeInput: %{
                 video: %{mimeType: "image/jpeg", data: b64}
               }
             } = GeminiProtocol.video_input_frame(@jpeg_a)

      assert Base.decode64!(b64) == @jpeg_a
    end

    test "prioritizes screen over cameras, follows active speaker camera, and rate-caps sends" do
      test = self()
      clock = :atomics.new(1, signed: true)
      :atomics.put(clock, 1, 1_000)

      spec =
        Spec.processor(:gemini, GeminiLive,
          model: "gemini-3.8-live",
          min_video_interval_ms: 900,
          video_ttl_ms: 5_000,
          clock: fn -> :atomics.get(clock, 1) end,
          send: fn msg -> send(test, {:gemini_sent, msg}) end
        )

      {:ok, core} = Core.new(spec, %{})
      assert_receive {:gemini_sent, {:connect, _}}

      # Before setup_complete, frames are not sent.
      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_a,
          source: "alice/camera",
          track_source: "camera"
        })

      refute_receive {:gemini_sent, {:video, _, _}}

      # Setup completes; Alice's camera streams.
      {_, core} = Core.info(core, :gemini, {:gemini_live_socket, :setup_complete})

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_a,
          source: "alice/camera",
          track_source: "camera"
        })

      assert_receive {:gemini_sent, {:video, @jpeg_a, mime_type: "image/jpeg"}}

      # Within min_video_interval_ms (900ms), another frame is throttled.
      :atomics.put(clock, 1, 1_500)

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_a,
          source: "alice/camera",
          track_source: "camera"
        })

      refute_receive {:gemini_sent, {:video, _, _}}

      # Active speaker switches to Bob; after interval, Bob's camera wins over Alice's.
      {_, core} = Core.info(core, :gemini, {:octoroom_agent_active_speaker, "bob"})
      :atomics.put(clock, 1, 2_000)

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_b,
          source: "bob/camera",
          track_source: "camera"
        })

      assert_receive {:gemini_sent, {:video, @jpeg_b, mime_type: "image/jpeg"}}

      # Carol shares screen: screen beats Bob's camera.
      :atomics.put(clock, 1, 3_000)

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_screen,
          source: "carol/screen",
          track_source: "screen"
        })

      assert_receive {:gemini_sent, {:video, @jpeg_screen, mime_type: "image/jpeg"}}

      # Bob's camera frame is ignored while Carol's screen is active.
      :atomics.put(clock, 1, 4_000)

      {_, core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_b,
          source: "bob/camera",
          track_source: "camera"
        })

      refute_receive {:gemini_sent, {:video, _, _}}

      # Once Carol stops sharing, Bob's camera resumes immediately on next tick.
      {_, core} = Core.push(core, %Frames.VideoInactive{source: "carol/screen"})
      :atomics.put(clock, 1, 5_000)

      {_, _core} =
        Core.push(core, %Frames.InputImage{
          image: @jpeg_b,
          source: "bob/camera",
          track_source: "camera"
        })

      assert_receive {:gemini_sent, {:video, @jpeg_b, mime_type: "image/jpeg"}}
    end
  end

  describe "OpenAI Live graceful handling" do
    test "ignores InputImage and VideoInactive while storing frames in tool context" do
      test = self()

      spec =
        Spec.processor(:openai, OpenAILive,
          model: "gpt-live-1.1",
          send: fn msg -> send(test, {:openai_sent, msg}) end
        )

      {:ok, core} = Core.new(spec, %{})
      assert_receive {:openai_sent, {:connect, _}}

      {cmds1, core} = Core.push(core, %Frames.InputImage{image: @jpeg_a, source: "alice/camera"})
      assert cmds1 == []

      {cmds2, core} = Core.push(core, %Frames.VideoInactive{source: "alice/camera"})
      assert cmds2 == []

      frames = %{"alice/camera" => %{data: @jpeg_a, source: "camera", speaker: "Alice"}}
      {_, core} = Core.info(core, :openai, {:octoroom_agent_frames, frames})
      assert Core.stage_state(core, :openai).context.frames == frames
    end
  end
end
