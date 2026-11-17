defmodule Octoroom.Agent.Processors.AudioTurns do
  @moduledoc """
  Turn taking with no STT, for the half-cascaded pipeline: the LLM hears each
  user turn as audio.

  Recording starts at the VAD start, with about `min_speech_ms + 500` ms of
  audio from before it (the VAD confirms speech late). The turn ends when
  Smart Turn calls it complete at a VAD stop, after `max_silence_ms` of
  pause, or, with `smart_turn: false`, at the VAD stop. The whole turn goes
  downstream as one `UserAudio` frame after `UserStoppedSpeaking`. Turns
  shorter than `min_audio_ms` are dropped as noise. Raw audio stops here.

  `source` is stamped from the audio. With `interrupt: false` (an agent's
  per-speaker front end) no `Interruption` is pushed: the agent decides who
  may interrupt.

  Options: `:interrupt` (default `true`), `:smart_turn` (default `true`), `:threshold`, `:max_silence_ms`,
  `:min_speech_ms`, `:min_audio_ms` (150), `:model_path`,
  `:features_model_path`, and `:predict` (a `fn pcm -> probability end`, for
  tests).
  """

  use Octoroom.Agent.Processor.StateMachine

  require Logger

  alias Octoroom.Agent.TurnDetection.SmartTurn
  alias Octoroom.Agent.VAD

  @sample_rate 16_000
  @pre_speech_ms 500

  @impl true
  def init(opts, _ctx) do
    smart_turn? = Keyword.get(opts, :smart_turn, true)

    model =
      cond do
        not smart_turn? ->
          {:ok, nil}

        Keyword.has_key?(opts, :predict) ->
          {:ok, nil}

        true ->
          SmartTurn.new(
            model_path: opts[:model_path],
            features_model_path: opts[:features_model_path]
          )
      end

    with {:ok, model} <- model do
      min_speech_ms = Keyword.get(opts, :min_speech_ms, VAD.defaults().min_speech_ms)

      {:ok, :idle,
       %{
         smart_turn?: smart_turn?,
         interrupt?: Keyword.get(opts, :interrupt, true),
         source: nil,
         model: model,
         predict: Keyword.get(opts, :predict),
         threshold: Keyword.get(opts, :threshold, 0.5),
         max_silence_ms: Keyword.get(opts, :max_silence_ms, 3_000),
         min_audio_ms: Keyword.get(opts, :min_audio_ms, 150),
         preroll_bytes: bytes(min_speech_ms + @pre_speech_ms),
         preroll: <<>>,
         audio: <<>>,
         turn_id: 0
       }}
    end
  end

  @impl true
  def handle_event(%Frames.Start{} = frame, _state, _data),
    do: {:keep_state_and_data, [{:push, frame, :downstream}, {:notify, {:status, "Listening"}}]}

  def handle_event(%Frames.InputAudio{audio: audio, source: source}, :idle, data) do
    data = %{data | source: source}
    preroll = data.preroll <> audio
    skip = max(byte_size(preroll) - data.preroll_bytes, 0)
    {:keep_state, %{data | preroll: binary_part(preroll, skip, byte_size(preroll) - skip)}}
  end

  def handle_event(%Frames.InputAudio{audio: audio}, _recording, data),
    do: {:keep_state, %{data | audio: data.audio <> audio}}

  def handle_event(%Frames.VADUserStartedSpeaking{} = frame, :idle, data) do
    interruption =
      if data.interrupt?, do: [{:push, %Frames.Interruption{}, :downstream}], else: []

    {:next_state, :speaking, %{data | audio: data.preroll, preroll: <<>>},
     [
       {:push, frame, :downstream},
       {:push, %Frames.UserStartedSpeaking{source: data.source}, :downstream} | interruption
     ]}
  end

  # The user kept talking after a pause.
  def handle_event(%Frames.VADUserStartedSpeaking{} = frame, :paused, data),
    do: {:next_state, :speaking, data, [{:push, frame, :downstream}]}

  def handle_event(
        %Frames.VADUserStoppedSpeaking{} = frame,
        :speaking,
        %{smart_turn?: false} = data
      ),
      do: finish_turn(data, [{:push, frame, :downstream}])

  def handle_event(%Frames.VADUserStoppedSpeaking{} = frame, :speaking, data) do
    {micros, probability} = :timer.tc(fn -> predict(data) end)
    complete? = probability >= data.threshold

    Logger.info(
      "SMART_TURN probability=#{Float.round(probability, 3)} complete=#{complete?} inference_ms=#{div(micros, 1_000)}"
    )

    effects = [
      {:push, frame, :downstream},
      {:notify, {:turn_prediction, %{probability: probability, complete: complete?}}}
    ]

    if complete?,
      do: finish_turn(data, effects),
      else:
        {:next_state, :paused, data, effects ++ [{:state_timeout, data.max_silence_ms, :silence}]}
  end

  def handle_event({:state_timeout, :silence}, :paused, data), do: finish_turn(data, [])
  def handle_event(%Frames.Interruption{}, _state, data), do: {:keep_state, data}

  defp finish_turn(data, effects) do
    audio = data.audio
    data = %{data | audio: <<>>, preroll: <<>>}

    if duration_ms(audio) < data.min_audio_ms do
      # Too short to be a turn: noise.
      {:next_state, :idle, data, effects}
    else
      turn_id = data.turn_id + 1
      Logger.info("AUDIO_TURN event=committed turn=#{turn_id} audio_ms=#{duration_ms(audio)}")

      {:next_state, :idle, %{data | turn_id: turn_id},
       effects ++
         [
           {:notify, {:status, "Thinking"}},
           {:push, %Frames.UserStoppedSpeaking{turn_id: turn_id, source: data.source},
            :downstream},
           {:push, %Frames.UserAudio{turn_id: turn_id, audio: audio, source: data.source},
            :downstream}
         ]}
    end
  end

  defp predict(%{predict: predict, audio: audio}) when is_function(predict, 1),
    do: predict.(audio)

  defp predict(data) do
    SmartTurn.predict_pcm(data.model, data.audio)
  rescue
    error ->
      Logger.warning("Smart Turn inference failed: #{Exception.message(error)}")
      1.0
  end

  defp bytes(ms), do: div(@sample_rate * 2 * ms, 1_000)
  defp duration_ms(pcm), do: div(byte_size(pcm) * 1_000, @sample_rate * 2)
end
