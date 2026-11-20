defmodule Octoroom.Agent.OpenAILive.ProtocolTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.OpenAILive.Protocol
  alias Octoroom.Agent.Tool

  test "session_start_frame carries model, voice, audio format, instructions and initial_items" do
    frame =
      Protocol.session_start_frame(
        model: "openai:gpt-live-1.1",
        voice: "cedar",
        instructions: "Be brief.",
        initial_items: [%{role: "user", content: [%{type: "text", text: "Hi"}]}],
        event_id: "evt_1"
      )

    assert frame == %{
             type: "session.start",
             event_id: "evt_1",
             session: %{
               model: "gpt-live-1.1",
               instructions: "Be brief.",
               audio: %{
                 format: %{type: "audio/pcm", rate: 24_000},
                 output: %{voice: "cedar"}
               },
               initial_items: [%{role: "user", content: [%{type: "text", text: "Hi"}]}]
             }
           }

    assert_raise KeyError, fn -> Protocol.session_start_frame(voice: "marin") end

    minimal = Protocol.session_start_frame(model: "gpt-live-1.1")
    assert minimal.session.audio.output.voice == "marin"
    refute Map.has_key?(minimal.session, :instructions)
    refute Map.has_key?(minimal.session, :delegation)
    refute Map.has_key?(minimal.session, :initial_items)
  end

  test "delegation supports :client, Responses delegation with merged tools, and validates options" do
    assert %{session: %{delegation: %{type: "client"}}} =
             Protocol.session_start_frame(model: "gpt-live-1.1", delegation: :client)

    assert %{session: %{delegation: %{type: "client"}}} =
             Protocol.session_start_frame(model: "gpt-live-1.1", delegation: [type: :client])

    tool = %Tool{
      name: "get_weather",
      description: "Get weather.",
      parameters: %{type: "object", properties: %{location: %{type: "string"}}},
      handler: fn _, _ -> %{} end
    }

    %{session: %{delegation: delegation}} =
      Protocol.session_start_frame(
        model: "gpt-live-1.1",
        delegation: [
          model: "openai:gpt-5.4-mini",
          instructions: "Use tools.",
          max_output_tokens: 1024,
          tools: [%{type: "web_search"}],
          tool_choice: "auto",
          parallel_tool_calls: true
        ],
        tools: [tool]
      )

    assert delegation == %{
             type: "responses",
             responses: %{
               model: "gpt-5.4-mini",
               instructions: "Use tools.",
               max_output_tokens: 1024,
               tool_choice: "auto",
               parallel_tool_calls: true,
               tools: [
                 %{type: "web_search"},
                 %{
                   type: "function",
                   name: "get_weather",
                   description: "Get weather.",
                   parameters: %{type: "object", properties: %{location: %{type: "string"}}}
                 }
               ]
             }
           }

    for bad <- [
          [],
          [type: :responses],
          [type: :responses, model: ""],
          [type: :client, model: "gpt-5.4-mini"],
          [type: :unknown, model: "gpt-5.4-mini"],
          [unknown: 1],
          :invalid
        ] do
      assert_raise ArgumentError, fn ->
        Protocol.session_start_frame(model: "gpt-live-1.1", delegation: bad)
      end
    end

    assert_raise ArgumentError, fn ->
      Protocol.session_start_frame(model: "gpt-live-1.1", sample_rate: 8_000)
    end
  end

  test "encodes audio, mute/unmute, context appends, tool outputs and session close" do
    assert %{type: "session.input_audio.append", audio: encoded} =
             Protocol.audio_input_frame(<<1, 2, 3, 4>>)

    assert Base.decode64!(encoded) == <<1, 2, 3, 4>>
    assert Protocol.input_audio_mute_frame() == %{type: "session.input_audio.mute"}
    assert Protocol.input_audio_unmute_frame() == %{type: "session.input_audio.unmute"}
    assert Protocol.session_close_frame() == %{type: "session.close"}

    assert Protocol.commentary_append_frame("Booked it.") == %{
             type: "session.commentary.append",
             delegation_id: nil,
             content: "Booked it."
           }

    assert Protocol.thinking_append_frame("Checking.", delegation_id: "del_1") == %{
             type: "session.thinking.append",
             delegation_id: "del_1",
             content: "Checking."
           }

    assert Protocol.instructions_append_frame("Speak French.") == %{
             type: "session.instructions.append",
             delegation_id: nil,
             content: "Speak French."
           }

    assert Protocol.tool_output_frame("call_1", %{ok: true}) == %{
             type: "response.item.create",
             item: %{
               type: "function_call_output",
               call_id: "call_1",
               output: ~s({"ok":true})
             }
           }

    assert Protocol.response_create_frame() == %{type: "response.create"}
  end

  test "decodes session lifecycle, audio, transcripts, delegation, tool calls and errors" do
    assert {:ok, [{:session_started, %{"id" => "live_1", "model" => "gpt-live-1.1"}}]} =
             Protocol.decode_frame(
               ~s({"type":"session.started","session":{"id":"live_1","model":"gpt-live-1.1"}})
             )

    audio_frame =
      Jason.encode!(%{type: "session.output_audio.delta", delta: Base.encode64(<<9, 9>>)})

    assert {:ok, [{:audio, <<9, 9>>, sample_rate: 24_000}]} =
             Protocol.decode_frame({:text, audio_frame})

    assert {:ok, [{:audio, <<9, 9>>, sample_rate: 16_000}]} =
             Protocol.decode_frame({:text, audio_frame}, sample_rate: 16_000)

    assert {:ok, [{:transcription, :user, "What is"}]} =
             Protocol.decode_frame(
               ~s({"type":"session.input_transcript.delta","delta":"What is"})
             )

    assert {:ok, [{:transcription, :assistant, "Sunny."}]} =
             Protocol.decode_frame(
               ~s({"type":"session.output_transcript.delta","delta":"Sunny."})
             )

    assert {:ok, [{:delegation_created, %{"id" => "del_1"}}]} =
             Protocol.decode_frame(
               ~s({"type":"session.delegation.created","delegation":{"id":"del_1"}})
             )

    tool_frame =
      Jason.encode!(%{
        type: "response.event",
        delegation_id: "del_1",
        event: %{
          type: "response.output_item.done",
          item: %{
            type: "function_call",
            call_id: "call_1",
            name: "add_row",
            arguments: ~s({"name":"Acme"})
          }
        }
      })

    assert {:ok, [{:tool_call, [%{id: "call_1", name: "add_row", args: %{"name" => "Acme"}}]}]} =
             Protocol.decode_frame(tool_frame)

    assert {:ok, [{:error, %{"code" => "invalid_request"}}]} =
             Protocol.decode_frame(~s({"type":"error","error":{"code":"invalid_request"}}))

    assert {:ok, [{:session_closed, "close_requested", _}]} =
             Protocol.decode_frame(~s({"type":"session.closed","reason":"close_requested"}))

    assert {:ok, [{:ack, "session.commentary.appended", _}]} =
             Protocol.decode_frame(~s({"type":"session.commentary.appended"}))
  end
end
