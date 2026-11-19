defmodule Octoroom.Agent.GeminiLive.ProtocolTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.GeminiLive.Protocol

  test "the setup frame carries the voice, instructions, tools and a resumption handle" do
    %{setup: setup} =
      Protocol.setup_frame(
        voice: "Puck",
        system_instruction: "Be brief.",
        tools: [%{functionDeclarations: []}],
        resumption_handle: "h1"
      )

    assert setup.model == Protocol.default_model()
    assert Protocol.setup_frame(model: "gemini-3.8-live").setup.model == "models/gemini-3.8-live"

    assert setup.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName ==
             "Puck"

    assert setup.systemInstruction == %{parts: [%{text: "Be brief."}]}
    assert setup.tools == [%{functionDeclarations: []}]
    assert setup.sessionResumption == %{handle: "h1"}

    # A first connection asks for handles without one.
    assert Protocol.setup_frame().setup.sessionResumption == %{}
    refute Map.has_key?(Protocol.setup_frame().setup, :systemInstruction)
  end

  test "audio goes up base64 at 16 kHz" do
    assert %{realtimeInput: %{audio: %{mimeType: "audio/pcm;rate=16000", data: data}}} =
             Protocol.audio_input_frame(<<1, 2, 3, 4>>)

    assert Base.decode64!(data) == <<1, 2, 3, 4>>
    assert Protocol.audio_stream_end_frame() == %{realtimeInput: %{audioStreamEnd: true}}
  end

  test "decodes audio, transcripts, interruptions and the end of a turn" do
    frame =
      Jason.encode!(%{
        serverContent: %{
          modelTurn: %{
            parts: [
              %{inlineData: %{mimeType: "audio/pcm;rate=24000", data: Base.encode64(<<9, 9>>)}}
            ]
          },
          inputTranscription: %{text: "hi"},
          outputTranscription: %{text: "Hello", finished: true},
          turnComplete: true
        }
      })

    assert {:ok, events} = Protocol.decode_frame({:text, frame})

    assert events == [
             {:audio, <<9, 9>>, sample_rate: 24_000},
             {:transcription, :user, "hi", false},
             {:transcription, :assistant, "Hello", true},
             :turn_complete
           ]

    assert {:ok, [:interrupted]} =
             Protocol.decode_frame(~s({"serverContent": {"interrupted": true}}))

    assert {:ok, [:setup_complete]} = Protocol.decode_frame(~s({"setupComplete": {}}))
  end

  test "decodes tool calls, resumption handles and goAway" do
    assert {:ok, [{:tool_call, [%{id: "c1", name: "add_row", args: %{"name" => "Acme"}}]}]} =
             Protocol.decode_frame(
               ~s({"toolCall": {"functionCalls": [{"id": "c1", "name": "add_row", "args": {"name": "Acme"}}]}})
             )

    assert {:ok, [{:resumption, "h2"}]} =
             Protocol.decode_frame(
               ~s({"sessionResumptionUpdate": {"newHandle": "h2", "resumable": true}})
             )

    assert {:ok, []} =
             Protocol.decode_frame(~s({"sessionResumptionUpdate": {"resumable": false}}))

    assert {:ok, [{:go_away, "10s"}]} = Protocol.decode_frame(~s({"goAway": {"timeLeft": "10s"}}))
  end
end
