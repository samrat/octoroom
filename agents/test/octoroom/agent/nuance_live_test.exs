defmodule Octoroom.Agent.NuanceLiveTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.NuanceLive.{Protobuf, Protocol, Signal}
  alias Octoroom.Agent.Pipeline.{Core, Spec}
  alias Octoroom.Agent.Processors.NuanceLive
  alias Octoroom.Agent.Tool

  describe "Protobuf" do
    test "encodes SignalRequest messages as binaries and decodes SignalResponse" do
      offer_bin = Protobuf.encode_offer("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n")
      assert is_binary(offer_bin)

      answer_bin = Protobuf.encode_answer("v=0\r\n", 42)
      assert is_binary(answer_bin)

      # Answer in SignalResponse is field 2 (same tag as SignalRequest.answer)
      assert {:ok, {:answer, %{type: "answer", sdp: "v=0\r\n", id: 42}}} =
               Protobuf.decode_signal_response(answer_bin)

      trickle_bin = Protobuf.encode_trickle(~s({"candidate":"c"}), :subscriber)
      assert is_binary(trickle_bin)

      add_track_bin =
        Protobuf.encode_add_track(%{
          cid: "mic-1",
          name: "microphone",
          type: :audio,
          source: :microphone,
          disable_red: true
        })

      assert is_binary(add_track_bin)
      assert is_binary(Protobuf.encode_leave())
      assert is_binary(Protobuf.encode_ping(123_456))
    end

    test "round-trips reliable DataPacket with UserPacket payload and topic" do
      payload = Jason.encode!(%{type: "response.create"})
      pkt = Protobuf.encode_user_packet(payload, "nuance_live", kind: :reliable, sequence: 7)

      assert {:ok, {:user, %{payload: ^payload, topic: "nuance_live"}}} =
               Protobuf.decode_data_packet(pkt)
    end

    test "encodes and decodes large text stream into header, chunks, and trailer" do
      text = String.duplicate("a", 35_000)
      pkts = Protobuf.encode_text_stream(text, "nuance_live", "stream-1")
      # 1 header + 3 chunks (15k, 15k, 5k) + 1 trailer
      assert length(pkts) == 5
      assert Enum.all?(pkts, &is_binary/1)

      [h, c0, c1, c2, t] = pkts

      assert {:ok, {:stream_header, %{stream_id: "stream-1", topic: "nuance_live"}}} =
               Protobuf.decode_data_packet(h)

      assert {:ok, {:stream_chunk, %{stream_id: "stream-1", chunk_index: 0, content: b0}}} =
               Protobuf.decode_data_packet(c0)

      assert {:ok, {:stream_chunk, %{stream_id: "stream-1", chunk_index: 1, content: b1}}} =
               Protobuf.decode_data_packet(c1)

      assert {:ok, {:stream_chunk, %{stream_id: "stream-1", chunk_index: 2, content: b2}}} =
               Protobuf.decode_data_packet(c2)

      assert b0 <> b1 <> b2 == text

      assert {:ok, {:stream_trailer, %{stream_id: "stream-1"}}} =
               Protobuf.decode_data_packet(t)
    end
  end

  describe "Signal.rtc_url/2" do
    test "converts https to wss and appends /rtc with query params" do
      url = Signal.rtc_url("https://lk.example.com/", "jwt_tok")
      assert String.starts_with?(url, "wss://lk.example.com/rtc?")
      assert url =~ "access_token=jwt_tok"
      assert url =~ "auto_subscribe=1"
      assert url =~ "protocol=15"
    end
  end

  describe "Protocol" do
    test "builds session token and conversation payloads" do
      tool = %Tool{
        name: "get_weather",
        description: "Look up weather",
        parameters: %{type: "object", properties: %{city: %{type: "string"}}},
        handler: fn _, _ -> %{} end
      }

      body =
        Protocol.session_token_request(
          persona: "sonia",
          instructions: "You are Sonia.",
          expressiveness: 1.2,
          tools: [tool],
          runtime_tools: [stay_quiet: true, end_call: true],
          end_user_id: "room/with spaces!"
        )

      assert body.interface == "nuance_live"
      assert body.personality == %{persona_id: "sonia", system_prompt: "You are Sonia."}
      assert body.expressiveness == 1.2
      assert body.end_user_id == "room_with_spaces_"
      assert body.interface_setup.video == %{input: %{camera: false}}

      cam_body = Protocol.session_token_request(persona: "sam", camera: true)
      assert cam_body.interface_setup.video == %{input: %{camera: true}}
      assert body.interface_setup.runtime_tools == %{"stay_quiet" => true, "end_call" => true}
      assert body.interface_setup.delegation.type == "responses"
      assert body.interface_setup.delegation.responses.model == "default"

      assert [%{type: "function", name: "get_weather"}] =
               body.interface_setup.delegation.responses.tools

      conv =
        Protocol.conversation_request(
          timezone: "Europe/London",
          max_session_seconds: 120,
          green_screen: true
        )

      assert conv == %{
               timezone: "Europe/London",
               max_session_seconds: 120,
               green_screen: true
             }
    end

    test "handles clock_sync_ping -> clock_sync_pong" do
      ping = Jason.encode!(%{type: "clock_sync_ping", seq: 3, t0: 100.5})
      assert {:ok, pong_json} = Protocol.handle_clock_sync(ping, 100.6, 100.61)

      assert %{
               "type" => "clock_sync_pong",
               "seq" => 3,
               "t0" => 100.5,
               "t1" => 100.6,
               "t2" => 100.61
             } == Jason.decode!(pong_json)
    end

    test "reassembles message.part packets" do
      full = Jason.encode!(%{type: "session.output_transcript.delta", delta: "Hello world!"})
      {p1, p2} = String.split_at(full, 20)

      part0 = Jason.encode!(%{type: "message.part", id: "evt_1", index: 0, count: 2, text: p1})
      part1 = Jason.encode!(%{type: "message.part", id: "evt_1", index: 1, count: 2, text: p2})

      assert {:ok, [], parts} = Protocol.decode_packet(part0, [])

      assert {:ok, [{:transcription, :assistant, "Hello world!"}], []} =
               Protocol.decode_packet(part1, parts)
    end

    test "validates persona and expressiveness" do
      assert_raise ArgumentError, ~r/persona/, fn -> Protocol.persona("invalid") end
      assert_raise ArgumentError, ~r/expressiveness/, fn -> Protocol.expressiveness(3.0) end
    end
  end

  describe "Spec.nuance_live/1 and Agent.agent/3 video: true" do
    test "builds mixed spec and agent spec with video output" do
      assert {nil, %Spec{stages: [%{name: :nuance, module: NuanceLive}]}} =
               Spec.nuance_live(persona: "mira")

      defmodule DummyVideoAgent do
        use Octoroom.Agent
        @impl true
        def pipeline(_ctx), do: Spec.nuance_live(persona: "sam")
      end

      spec =
        Octoroom.Agent.agent("sam", DummyVideoAgent,
          hears: ["alice/mic"],
          sees: ["alice/camera"],
          video: true,
          video_inputs: :rtp
        )

      assert spec.inputs == ["alice/mic", "alice/camera"]
      assert spec.outputs == ["sam", "sam/video"]
      assert spec.output_kinds == %{"sam/video" => :video}
      assert spec.video_inputs == :rtp
    end
  end

  def lookup_tool(call, _ctx), do: %{id: call.id, name: call.name, response: %{answer: 42}}

  describe "Processors.NuanceLive" do
    test "bridges audio, video RTP, PLI, initial greeting, transcripts, and tools" do
      test_pid = self()

      tool = %Tool{
        name: "lookup",
        description: "Look up info",
        parameters: %{type: "object", properties: %{q: %{type: "string"}}},
        handler: {__MODULE__, :lookup_tool}
      }

      {nil, spec} = Spec.nuance_live(persona: "sam", send: &send(test_pid, {:sent, &1}))

      {:ok, core} =
        Core.new(spec, %{
          owner: test_pid,
          runner: test_pid,
          instructions: "You are Sam.",
          initial_text: "Say hello!",
          tools: [tool]
        })

      assert_receive {:sent, {:connect, _}}

      # Start frame + session.started triggers initial greeting via response.create
      {_cmds, core} = Core.push(core, %Frames.Start{session_id: "s1"})

      {_cmds, core} =
        Core.info(core, :broadcast, {:nuance_live_socket, {:session_started, %{}}})

      assert_receive {:sent,
                      {:json, %{type: "response.create", response: %{instructions: "Say hello!"}}}}

      # Video RTP passes straight through as OutputVideo with its codec
      vp9_pkt = ExRTP.Packet.new(<<0x87, 0x00>>, sequence_number: 1, timestamp: 90, marker: true)

      {cmds, core} =
        Core.info(core, :broadcast, {:nuance_live_socket, {:video_rtp, vp9_pkt, :vp9}})

      assert [{:output, %Frames.OutputVideo{packet: ^vp9_pkt, codec: :vp9}}] = cmds

      # Video PLI requests a keyframe from LiveKit
      {_cmds, core} = Core.info(core, :broadcast, :octoroom_video_pli)
      assert_receive {:sent, :request_keyframe}

      # Inbound camera video RTP forwards to Nuance Live and relays PLI upstream
      cam_pkt =
        ExRTP.Packet.new(<<0x10, 0x01>>, sequence_number: 7, timestamp: 3000, marker: true)

      {_cmds, core} =
        Core.push(core, %Frames.InputVideo{
          packet: cam_pkt,
          source: "alice/camera",
          codec: :vp8
        })

      assert_receive {:sent, {:video, ^cam_pkt, :vp8}}

      {cmds, core} = Core.info(core, :broadcast, {:nuance_live_socket, :camera_pli})
      assert [{:notify, {:request_pli, "alice/camera"}}] = cmds

      # Audio + output transcript + output_audio.done produces OutputAudio and AssistantMessage
      pcm = <<1, 0, 2, 0, 3, 0, 4, 0>>

      {cmds, core} =
        Core.info(core, :broadcast, {:nuance_live_socket, {:audio, pcm, sample_rate: 24_000}})

      assert [{:output, %Frames.OutputAudio{audio: ^pcm, sample_rate: 24_000}}] = cmds

      {_cmds, core} =
        Core.info(
          core,
          :broadcast,
          {:nuance_live_socket, {:transcription, :assistant, "Hi there!"}}
        )

      {cmds, core} =
        Core.info(core, :broadcast, {:nuance_live_socket, {:output_audio_done, "completed", %{}}})

      assert [{:output, %Frames.AssistantMessage{text: "Hi there!", interrupted?: false}}] = cmds

      # Tool call waits for both response.completed and tool execution before sending outputs + response.create
      call = %{id: "call_1", name: "lookup", args: %{"q" => "life"}}

      {_cmds, core} =
        Core.info(core, :broadcast, {:nuance_live_socket, {:tool_call, "del_1", [call]}})

      assert_receive {:octoroom_agent_async_tool_result, result}, 1_000
      {_cmds, core} = Core.info(core, :broadcast, {:octoroom_agent_async_tool_result, result})
      refute_received {:sent, {:json, %{type: "response.create"}}}

      {_cmds, _core} =
        Core.info(core, :broadcast, {:nuance_live_socket, {:response_completed, "del_1", %{}}})

      assert_receive {:sent,
                      {:json,
                       %{
                         type: "response.item.create",
                         item: %{type: "function_call_output", call_id: "call_1"}
                       }}}

      assert_receive {:sent, {:json, %{type: "response.create"}}}
    end

    test "marks startup failures as fatal and Agent.Worker sets error presence and catches up subscribers" do
      test_pid = self()
      {nil, spec} = Spec.nuance_live(persona: "sam", send: &send(test_pid, {:sent, &1}))
      {:ok, core} = Core.new(spec, %{owner: test_pid, runner: test_pid})

      err = {:session_token_failed, 429, %{"code" => "credits_spent", "detail" => "No credits"}}

      {cmds, _core} = Core.info(core, :broadcast, {:nuance_live_socket, {:error, err}})

      assert [
               {:output_upstream,
                %Frames.Error{processor: NuanceLive, reason: ^err, fatal?: true}}
             ] = cmds

      # Verify Agent.Worker transitions presence to "error" and replays the error to late subscribers.
      defmodule FatalErrorAgent do
        use Octoroom.Agent
        @impl true
        def pipeline(ctx), do: Spec.nuance_live(persona: "sam", send: ctx.args.send)
      end

      ctx = %Octoroom.Worker.Context{
        room_id: "nuance-err-room",
        id: "assistant",
        inputs: ["alice/mic"],
        outputs: ["assistant", "assistant/video"],
        output_kinds: %{"assistant/video" => :video},
        data: [],
        participants: []
      }

      {:ok, state, _init_actions} =
        Octoroom.Agent.Worker.init(
          %{agent: FatalErrorAgent, name: "Assistant", args: %{send: &send(test_pid, {:w, &1})}},
          ctx
        )

      {:ok, state, actions} =
        Octoroom.Agent.Worker.handle_info({:nuance_live_socket, {:error, err}}, state)

      assert {:presence, %{state: "error"}} =
               Enum.find(actions, &match?({:presence, %{state: "error"}}, &1))

      assert {:notify, {:default, "error", %{fatal: true, message: "No credits"}}} =
               Enum.find(actions, &match?({:notify, {:default, "error", _}}, &1))

      # Late subscriber receives the cached fatal error alongside transcript_snapshot.
      {:ok, _state, sub_actions} =
        Octoroom.Agent.Worker.handle_info({:octoroom, :subscribed, "alice", "assistant"}, state)

      assert {:notify, {"assistant", "error", %{fatal: true, message: "No credits"}, "alice"}} =
               Enum.find(sub_actions, &match?({:notify, {"assistant", "error", _, "alice"}}, &1))
    end
  end
end
