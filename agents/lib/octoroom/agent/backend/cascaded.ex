defmodule Octoroom.Agent.Backend.Cascaded do
  @moduledoc """
  Configuration for a cascaded agent: speech-to-text, an LLM and
  text-to-speech, with a local VAD for barge-in. `new/1` fills in defaults:
  Soniox, Gemini through ReqLLM, and Inworld.

  `speech_to_text` and `text_to_speech` take the options of
  `Octoroom.Agent.STT` and `Octoroom.Agent.TTS`, or just a
  `"provider:model"` string: `%{stt: "soniox:stt-rt-v6", tts: "inworld"}`.
  The provider's own defaults fill in the rest.
  """

  alias Octoroom.Agent.{SpeechProvider, STT, TTS}

  defstruct speech_to_text: %{
              provider: :soniox,
              sample_rate: 16_000,
              format_turns: false
            },
            llm: %{
              provider: :google,
              model: "gemini-3.5-flash",
              reasoning_effort: :minimal,
              stream: true
            },
            text_to_speech: %{
              provider: :inworld,
              output_sample_rate: 24_000
            },
            vad: %{
              enabled: true,
              start_threshold: 0.5,
              stop_threshold: 0.35,
              min_speech_ms: 200,
              min_silence_ms: 300
            },
            turn_detection: %{provider: :stt}

  @vad_defaults %{
    enabled: true,
    start_threshold: 0.5,
    stop_threshold: 0.35,
    min_speech_ms: 200,
    min_silence_ms: 300
  }

  @vad_keys ~w(enabled start_threshold stop_threshold min_speech_ms min_silence_ms model_path)a

  @smart_turn_defaults %{
    provider: :smart_turn,
    threshold: 0.5,
    max_silence_ms: 3_000,
    finalize_timeout_ms: 1_500
  }

  @smart_turn_keys ~w(threshold max_silence_ms finalize_timeout_ms model_path features_model_path)a

  # `speech_to_text: false` (or `provider: :none`) skips speech-to-text: the
  # LLM hears each user turn as audio. Only Gemini takes audio input, through
  # ReqLLM. `transcription_model` transcribes each turn in the background for
  # conversation events and to replace the audio in the history; `false`
  # turns that off.
  @audio_input_defaults %{
    provider: :none,
    sample_rate: 16_000,
    transcription_model: "gemini-3.1-flash-lite"
  }

  def new(opts \\ %{}) do
    speech_to_text = speech_to_text_config(opts)

    %__MODULE__{
      speech_to_text: speech_to_text,
      llm:
        value(opts, :llm, %{})
        |> then(&merge_defaults(&1, llm_defaults(&1))),
      text_to_speech: text_to_speech_config(value(opts, :text_to_speech, value(opts, :tts, %{}))),
      vad: vad_config(opts) |> require_vad(speech_to_text),
      turn_detection: turn_detection_config(opts)
    }
  end

  @doc "True when the LLM hears the user's audio instead of an STT transcript."
  def audio_input?(%__MODULE__{speech_to_text: stt}), do: audio_input_stt?(stt)

  def audio_input_stt?(%{provider: :none}), do: true
  def audio_input_stt?(_stt), do: false

  defp speech_to_text_config(opts) when is_map(opts) do
    raw =
      Enum.find_value([:speech_to_text, "speech_to_text", :stt, "stt"], %{}, fn key ->
        if Map.has_key?(opts, key), do: {:ok, Map.get(opts, key)}
      end)
      |> case do
        {:ok, value} -> value
        default -> default
      end

    case raw do
      none when none in [false, :none, "none"] ->
        @audio_input_defaults

      spec when is_binary(spec) or (is_atom(spec) and spec not in [nil, true]) ->
        speech_to_text_config(%{stt: Map.new(SpeechProvider.with_provider(spec, []))})

      map when is_map(map) ->
        config =
          map
          |> known_keys()
          |> speech_provider(STT.providers())
          |> merge_defaults(%{provider: :soniox, sample_rate: 16_000, format_turns: false})

        if config.provider == :none,
          do: Map.merge(@audio_input_defaults, Map.delete(config, :format_turns)),
          else: config

      _other ->
        merge_defaults(%{}, %{provider: :soniox, sample_rate: 16_000, format_turns: false})
    end
  end

  defp speech_to_text_config(_opts),
    do: %{provider: :soniox, sample_rate: 16_000, format_turns: false}

  # Without STT, the local VAD is the only thing that hears the user.
  defp require_vad(%{enabled: false} = vad, %{provider: :none}), do: %{vad | enabled: true}
  defp require_vad(vad, _speech_to_text), do: vad

  # Who decides that the user finished their turn. `:stt` (the default) waits
  # for the speech-to-text provider's own endpointing. `:smart_turn` runs
  # Pipecat's Smart Turn v3 model on the user's audio when the local VAD hears
  # silence, then asks the STT provider to finalize. It needs the VAD.
  defp turn_detection_config(opts) when is_map(opts) do
    case value(opts, :turn_detection, nil) do
      provider when provider in [:smart_turn, "smart_turn", true] ->
        @smart_turn_defaults

      map when is_map(map) ->
        case normalize_turn_provider(value(map, :provider, :stt)) do
          :smart_turn -> Map.merge(@smart_turn_defaults, pick_keys(map, @smart_turn_keys))
          _provider -> %{provider: :stt}
        end

      _other ->
        %{provider: :stt}
    end
  end

  defp turn_detection_config(_opts), do: %{provider: :stt}

  defp normalize_turn_provider("smart_turn"), do: :smart_turn
  defp normalize_turn_provider(provider), do: provider

  # Local Silero VAD drives barge-in. `vad: false` falls back to interrupting on
  # the first STT partial transcript.
  defp vad_config(opts) when is_map(opts) do
    raw =
      cond do
        Map.has_key?(opts, :vad) -> Map.get(opts, :vad)
        Map.has_key?(opts, "vad") -> Map.get(opts, "vad")
        true -> %{}
      end

    case raw do
      false -> %{@vad_defaults | enabled: false}
      nil -> @vad_defaults
      true -> @vad_defaults
      map when is_map(map) -> Map.merge(@vad_defaults, vad_keys(map))
      _other -> @vad_defaults
    end
  end

  defp vad_config(_opts), do: @vad_defaults

  defp vad_keys(map), do: pick_keys(map, @vad_keys)

  defp pick_keys(map, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      cond do
        Map.has_key?(map, key) ->
          Map.put(acc, key, Map.get(map, key))

        Map.has_key?(map, Atom.to_string(key)) ->
          Map.put(acc, key, Map.get(map, Atom.to_string(key)))

        true ->
          acc
      end
    end)
  end

  defp merge_defaults(opts, defaults) when is_map(opts) do
    defaults
    |> Map.merge(known_keys(opts))
    |> normalize_provider()
  end

  defp merge_defaults(_opts, defaults), do: defaults

  defp normalize_provider(config) do
    Map.update(config, :provider, nil, fn
      "none" -> :none
      "soniox" -> :soniox
      "gemini" -> :google
      "google" -> :google
      "inworld" -> :inworld
      "openai" -> :openai
      "openrouter" -> :openrouter
      "woof" -> :woof
      provider -> provider
    end)
  end

  defp normalize_provider_value("inworld"), do: :inworld
  defp normalize_provider_value("openai"), do: :openai
  defp normalize_provider_value("openrouter"), do: :openrouter
  defp normalize_provider_value("woof"), do: :woof
  defp normalize_provider_value(provider), do: provider

  defp llm_defaults(opts) do
    case normalize_provider_value(value(opts, :provider, :google)) do
      :openai ->
        %{
          provider: :openai,
          model: "gpt-5-mini"
        }

      # Nemotron 3.5 Lightning (30B-A3B) is NVIDIA's low-latency model. Reasoning
      # is off for voice, and OpenRouter routes to the lowest-latency host.
      :openrouter ->
        %{
          provider: :openrouter,
          model: "nvidia/nemotron-3.5-lightning",
          reasoning_effort: :none,
          stream: true,
          provider_options: [openrouter_provider: %{sort: "latency"}]
        }

      _provider ->
        %{
          provider: :google,
          model: "gemini-3.5-flash",
          reasoning_effort: :minimal,
          stream: true
        }
    end
  end

  # The provider's own defaults (model, voice, ...) are filled in here so the
  # config shows them; its `sample_rate` is the agent's `output_sample_rate`.
  defp text_to_speech_config(spec) when is_binary(spec) or (is_atom(spec) and not is_nil(spec)),
    do: text_to_speech_config(Map.new(SpeechProvider.with_provider(spec, [])))

  defp text_to_speech_config(opts) do
    config =
      if(is_map(opts), do: known_keys(opts), else: %{})
      |> speech_provider(TTS.providers())
      |> Map.put_new(:provider, :inworld)

    {rate, defaults} =
      TTS.default_options(provider: config.provider) |> Map.new() |> Map.pop(:sample_rate)

    defaults
    |> Map.put(:output_sample_rate, rate || 24_000)
    |> Map.merge(config)
  end

  # `%{model: "soniox:stt-rt-v6"}` names the provider; `"soniox"` becomes
  # `:soniox`.
  defp speech_provider(config, registry) do
    config = SpeechProvider.split_model(config, registry)

    case config do
      %{provider: provider} -> %{config | provider: SpeechProvider.name(provider, registry)}
      config -> config
    end
  end

  # String keys accepted from JSON config. Anything else is dropped rather than
  # turned into a new atom.
  @string_config_keys ~w(audio_encoding audio_format delivery_mode enable_endpoint_detection
                         end_of_turn_confidence_threshold endpoint_latency_adjustment_level
                         endpoint_sensitivity format_turns instructions language_hints max_tokens
                         max_endpoint_delay_ms max_turn_silence
                         min_end_of_turn_silence_when_confident model model_path num_channels
                         output_sample_rate provider reasoning_effort sample_rate speed stream
                         transcription_model timestamp_transport_strategy voice)a

  @key_aliases %{
    "deliveryMode" => :delivery_mode,
    "timestampTransportStrategy" => :timestamp_transport_strategy,
    "voice_id" => :voice,
    :voice_id => :voice
  }

  @config_keys Map.merge(Map.new(@string_config_keys, &{Atom.to_string(&1), &1}), @key_aliases)

  defp known_keys(map) do
    for {key, value} <- map, key = config_key(key), into: %{} do
      {key, normalize_value(key, value)}
    end
  end

  defp config_key(key) when is_map_key(@config_keys, key), do: Map.fetch!(@config_keys, key)
  defp config_key(key) when is_atom(key), do: key
  defp config_key(_key), do: nil

  @reasoning_efforts ~w(none minimal low medium high xhigh)

  defp normalize_value(:reasoning_effort, value) when value in @reasoning_efforts,
    do: String.to_atom(value)

  defp normalize_value(_key, value), do: value

  defp value(opts, key, default) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) || default
  end
end
