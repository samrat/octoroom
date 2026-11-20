defmodule Octoroom.Agent.GeminiLive.Protocol do
  @moduledoc """
  Gemini Live's wire format: the frames sent to it and the events its frames
  decode to. Pure, so it's tested without a socket.

  Copied from Subvocal, with session resumption and `audioStreamEnd` added.
  """

  @default_voice "Zephyr"
  @send_sample_rate 16_000

  def default_voice, do: @default_voice
  def send_sample_rate, do: @send_sample_rate

  @doc """
  The setup frame, the first thing sent on a connection. Options: `:model`
  (needed), `:voice`, `:response_modalities`, `:system_instruction`, `:tools` (Gemini
  declarations) and `:resumption_handle` (from a `{:resumption, handle}`
  event, to carry on the same session on a new connection).
  """
  def setup_frame(opts) do
    setup =
      %{
        model: model_name(Keyword.fetch!(opts, :model)),
        inputAudioTranscription: %{},
        outputAudioTranscription: %{},
        generationConfig: %{
          responseModalities: Keyword.get(opts, :response_modalities, ["AUDIO"]),
          speechConfig: %{
            voiceConfig: %{
              prebuiltVoiceConfig: %{voiceName: Keyword.get(opts, :voice, @default_voice)}
            }
          }
        },
        # Without compression, an audio session ends after about 15 minutes.
        contextWindowCompression: %{
          triggerTokens: 104_857,
          slidingWindow: %{targetTokens: 52_428}
        },
        # Asks for resumption handles, so a dropped connection (the server
        # closes each one after about 10 minutes) carries on the session.
        sessionResumption: resumption(Keyword.get(opts, :resumption_handle))
      }
      |> put_system_instruction(Keyword.get(opts, :system_instruction))
      |> put_tools(Keyword.get(opts, :tools, []))

    %{setup: setup}
  end

  def audio_input_frame(audio, opts \\ []) when is_binary(audio) do
    sample_rate = Keyword.get(opts, :sample_rate, @send_sample_rate)

    %{
      realtimeInput: %{
        audio: %{mimeType: "audio/pcm;rate=#{sample_rate}", data: Base.encode64(audio)}
      }
    }
  end

  @doc "Tells the model the audio stopped for a while, so it doesn't wait for more."
  def audio_stream_end_frame, do: %{realtimeInput: %{audioStreamEnd: true}}

  def text_input_frame(text) when is_binary(text), do: %{realtimeInput: %{text: text}}

  def tool_response_frame(function_responses) when is_list(function_responses),
    do: %{toolResponse: %{functionResponses: function_responses}}

  def decode_frame({:binary, data}), do: decode_json(data)
  def decode_frame({:text, data}), do: decode_json(data)
  def decode_frame(data) when is_binary(data), do: decode_json(data)

  @doc """
  The model as the API names it, `"models/..."`. Takes a bare name or a
  `gemini:` or `google:` prefix; nil is the default.
  """
  def model_name("models/" <> _ = model), do: model
  def model_name("gemini:" <> model), do: model_name(model)
  def model_name("google:" <> model), do: model_name(model)
  def model_name(model) when is_binary(model), do: "models/" <> model

  defp resumption(handle) when is_binary(handle), do: %{handle: handle}
  defp resumption(_none), do: %{}

  defp put_system_instruction(setup, text) when is_binary(text) and text != "",
    do: Map.put(setup, :systemInstruction, %{parts: [%{text: text}]})

  defp put_system_instruction(setup, _none), do: setup

  defp put_tools(setup, []), do: setup
  defp put_tools(setup, tools), do: Map.put(setup, :tools, tools)

  defp decode_json(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> {:ok, events(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp events(%{"setupComplete" => _}), do: [:setup_complete]

  defp events(%{"toolCall" => %{"functionCalls" => calls}}) when is_list(calls),
    do: [{:tool_call, Enum.map(calls, &function_call/1)}]

  defp events(%{"toolCallCancellation" => %{"ids" => ids}}) when is_list(ids),
    do: [{:tool_call_cancellation, ids}]

  defp events(%{"sessionResumptionUpdate" => update}) do
    case update do
      %{"resumable" => true, "newHandle" => handle} when is_binary(handle) ->
        [{:resumption, handle}]

      _not_resumable ->
        []
    end
  end

  defp events(%{"goAway" => go_away}), do: [{:go_away, go_away["timeLeft"]}]
  defp events(%{"serverContent" => content} = frame), do: content_events(content, frame)
  defp events(frame), do: [{:raw, frame}]

  defp content_events(content, frame) do
    parts = Enum.flat_map(get_in(content, ["modelTurn", "parts"]) || [], &part_events/1)

    transcripts =
      transcription_events(content["inputTranscription"], :user) ++
        transcription_events(content["outputTranscription"], :assistant)

    interrupted = if content["interrupted"] == true, do: [:interrupted], else: []
    complete = if content["turnComplete"] == true, do: [:turn_complete], else: []

    # Audio and text before the end of the turn, when one frame has both.
    case parts ++ transcripts ++ interrupted ++ complete do
      [] -> [{:raw, frame}]
      events -> events
    end
  end

  defp transcription_events(%{"text" => text} = transcript, role) when is_binary(text),
    do: [{:transcription, role, text, transcript["finished"] == true}]

  defp transcription_events(%{"finished" => true}, role), do: [{:transcription, role, "", true}]
  defp transcription_events(_none, _role), do: []

  defp part_events(%{"inlineData" => %{"data" => data, "mimeType" => "audio/pcm" <> rate}}),
    do: [{:audio, Base.decode64!(data), sample_rate: sample_rate(rate)}]

  defp part_events(%{"text" => text}) when is_binary(text), do: [{:text, text}]
  defp part_events(_part), do: []

  defp sample_rate(";rate=" <> rate), do: String.to_integer(rate)
  defp sample_rate(_none), do: 24_000

  defp function_call(call),
    do: %{id: call["id"], name: call["name"], args: call["args"] || %{}}
end
