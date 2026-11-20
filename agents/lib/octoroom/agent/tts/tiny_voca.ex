defmodule Octoroom.Agent.TTS.TinyVoca do
  @moduledoc """
  Local text-to-speech using [tiny-voca](https://huggingface.co/n4ze3m/tiny-voca)
  (4.5M parameters, Apache-2.0) running on ONNX Runtime via `OnnxRuntime`.

  No API key or external runtime is needed. On first use, the ONNX model
  (`onnx/model.onnx`, ~21.4 MB) and `dizione` phonemizer data (~5.4 MB) are
  downloaded from Hugging Face into the local cache directory and kept in
  `:persistent_term`.

  Built-in American English voices: `"F2"` (female, default) and `"M2"` (male).
  Native audio is 24 kHz mono s16le PCM; other `:sample_rate` values are
  resampled with `Octoroom.Agent.Audio.PCM16.resample/3`.

      {:ok, pcm} = Octoroom.Agent.TTS.synthesize("tiny_voca:tiny-voca", "Hello!", voice: "M2")

  Besides `Octoroom.Agent.TTS`'s options (`:model`, `:voice`, `:sample_rate`),
  it takes:

    * `:speed` - speaking rate multiplier (default `1.0`; larger is faster)
    * `:pitch_shift` - added to log F0 (default `0.0`; `0.058` ≈ one semitone)
    * `:pitch_range` - scales pitch movement around the mean (default `1.0`)
    * `:model_dir` - directory holding `onnx/model.onnx` and `phonemizer/`
      (defaults to `TINY_VOCA_DIR`, `:octoroom_agents`'s `:tiny_voca_dir`,
      or the OS user cache directory)
    * `:download` - download missing weights from Hugging Face on demand
      (default `true`)
    * `:overrides` - `%{word => pronunciation}` map of inline dictionary
      overrides (CMUdict ARPAbet or narrow IPA)
  """

  @behaviour Octoroom.Agent.TTS

  alias Octoroom.Agent.Audio.PCM16
  alias Octoroom.Agent.TTS.TinyVoca.{Dizione, Store}

  @native_sample_rate 24_000
  @max_tokens 512
  @token_limit @max_tokens - 12
  @peak 0.99

  @voices %{"F2" => 0, "M2" => 1}
  @models MapSet.new(["tiny-voca", "n4ze3m/tiny-voca"])

  @space_re ~r/[\s\x{FEFF}]+/u
  @sentence_end_re ~r/(?:(?<=[.!?…])|(?<=[.!?…]["')\]]))\s+(?=["'(\[]?[A-Z0-9])/u
  @not_an_end_re ~r/(?:\b(?:mr|mrs|ms|dr|prof|sr|jr|st|vs|etc|no|inc|ltd|co|e\.g|i\.e|a\.m|p\.m)|\b[A-Z])\.$/i
  @clause_end_re ~r/(?<=[,;:—])\s+/u
  @text_end_re ~r/[\s\x{FEFF}]+$/u
  @closing_chars MapSet.new(String.graphemes("\"'”’)]»"))

  @impl true
  def default_options do
    [
      voice: "F2",
      sample_rate: @native_sample_rate,
      speed: 1.0,
      pitch_shift: 0.0,
      pitch_range: 1.0
    ]
  end

  @doc """
  Ensures the model and phonemizer are downloaded and loaded into
  `:persistent_term` so the first spoken turn has no cold-load delay.
  """
  @impl true
  def connect(opts) do
    with {:ok, _cfg} <- validate_options(opts),
         {:ok, _bundle} <- Store.load(opts) do
      {:ok, opts}
    end
  end

  @impl true
  def stream(text, on_audio, opts) when is_binary(text) and is_function(on_audio, 1) do
    with {:ok, cfg} <- validate_options(opts),
         {:ok, %{model: model, phonemizer: base_phonemizer}} <- Store.load(opts) do
      phonemizer =
        case Keyword.get(opts, :overrides) do
          overrides when is_map(overrides) and map_size(overrides) > 0 ->
            Dizione.with_overrides(base_phonemizer, overrides)

          _ ->
            base_phonemizer
        end

      text
      |> finished()
      |> sentences()
      |> Enum.reduce_while(:ok, fn sentence, :ok ->
        case speak_piece(model, phonemizer, sentence, cfg, on_audio) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp speak_piece(model, phonemizer, piece, cfg, on_audio) do
    case Dizione.phonemize(phonemizer, piece) do
      {:error, :nothing_to_pronounce} ->
        :ok

      {:ok, %{ids: ids, stress: stress}} when length(ids) <= @token_limit ->
        case infer_utterance(model, ids, stress, cfg) do
          {:ok, pcm} ->
            if pcm != <<>>, do: on_audio.(pcm)
            :ok

          {:error, :utterance_too_long} ->
            speak_shorter(model, phonemizer, piece, cfg, on_audio)

          {:error, _} = err ->
            err
        end

      {:ok, _too_many_tokens} ->
        speak_shorter(model, phonemizer, piece, cfg, on_audio)
    end
  end

  defp speak_shorter(model, phonemizer, piece, cfg, on_audio) do
    case shorter(piece) do
      [] ->
        {:error, {:utterance_too_long, String.slice(piece, 0, 40)}}

      parts ->
        Enum.reduce_while(parts, :ok, fn part, :ok ->
          case speak_piece(model, phonemizer, part, cfg, on_audio) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)
    end
  end

  defp infer_utterance(model, ids, stress, cfg) do
    tokens_t = Nx.tensor([ids], type: :s64)
    stress_t = Nx.tensor([stress], type: :s64)
    voice_t = Nx.tensor([cfg.voice_id], type: :s64)
    speed_t = Nx.tensor([cfg.speed], type: :f32)
    pitch_shift_t = Nx.tensor([cfg.pitch_shift], type: :f32)
    pitch_range_t = Nx.tensor([cfg.pitch_range], type: :f32)

    try do
      {audio, _durations} =
        OnnxRuntime.run(
          model,
          {tokens_t, stress_t, voice_t, speed_t, pitch_shift_t, pitch_range_t}
        )

      raw = audio |> Nx.backend_transfer(Nx.BinaryBackend) |> Nx.to_binary()
      pcm = f32_to_pcm16(raw)

      pcm =
        if cfg.sample_rate == @native_sample_rate,
          do: pcm,
          else: PCM16.resample(pcm, @native_sample_rate, cfg.sample_rate)

      {:ok, pcm}
    rescue
      error ->
        msg = Exception.message(error)

        if String.contains?(msg, "max_frames") do
          {:error, :utterance_too_long}
        else
          {:error, {:tiny_voca_inference_failed, msg}}
        end
    end
  end

  # -- Audio conversion

  @doc false
  def f32_to_pcm16(<<>>), do: <<>>

  def f32_to_pcm16(raw) when is_binary(raw) do
    peak = peak_abs(raw, 0.0)
    scale = if peak > @peak, do: @peak / peak * 32_767.0, else: 32_767.0

    for <<sample::float-32-native <- raw>>, into: <<>> do
      clamped = sample |> Kernel.*(scale) |> round() |> max(-32_768) |> min(32_767)
      <<clamped::little-signed-16>>
    end
  end

  defp peak_abs(<<sample::float-32-native, rest::binary>>, acc) do
    a = abs(sample)
    peak_abs(rest, if(a > acc, do: a, else: acc))
  end

  defp peak_abs(<<>>, acc), do: acc

  # -- Text splitting (mirrors `tiny_voca/infer.py`)

  @doc false
  def sentences(text) when is_binary(text) do
    collapsed = text |> String.replace(@space_re, " ") |> String.trim()

    {parts, current} =
      @sentence_end_re
      |> Regex.split(collapsed)
      |> Enum.reduce({[], ""}, fn piece, {parts, current} ->
        combined = if current == "", do: piece, else: current <> " " <> piece

        if Regex.match?(@not_an_end_re, combined) do
          {parts, combined}
        else
          {[combined | parts], ""}
        end
      end)

    parts = if current != "", do: [current | parts], else: parts

    parts
    |> Enum.reverse()
    |> Enum.filter(&Regex.match?(~r/[\p{L}\p{N}]/u, &1))
  end

  @doc false
  def finished(text) when is_binary(text) do
    body = String.replace(text, @text_end_re, "")

    if body == "" do
      text
    else
      last = @space_re |> Regex.split(body) |> List.last()

      marked? =
        if Regex.match?(~r/[\p{L}\p{N}]/u, last) do
          stripped = strip_trailing_closing(last)
          String.last(stripped) in [".", "!", "?", "…", ",", ";", ":"]
        else
          String.contains?(last, [".", "!", "?", "…"]) or last in [",", ";", ":"]
        end

      if marked?, do: text, else: body <> "."
    end
  end

  defp strip_trailing_closing(str) do
    str
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.drop_while(&MapSet.member?(@closing_chars, &1))
    |> Enum.reverse()
    |> Enum.join()
  end

  @doc false
  def shorter(text) when is_binary(text) do
    pieces = Regex.split(@clause_end_re, text)

    if length(pieces) > 1 do
      pieces
    else
      words = String.split(text, " ")

      if length(words) < 2 do
        []
      else
        half = div(length(words) + 1, 2)
        {left, right} = Enum.split(words, half)
        [Enum.join(left, " "), Enum.join(right, " ")]
      end
    end
  end

  # -- Option validation

  defp validate_options(opts) do
    with {:ok, _model} <- validate_model(Keyword.get(opts, :model)),
         {:ok, voice_id} <- validate_voice(Keyword.get(opts, :voice, "F2")),
         {:ok, sample_rate} <-
           validate_sample_rate(Keyword.get(opts, :sample_rate, @native_sample_rate)),
         {:ok, speed} <- validate_positive_float(:speed, Keyword.get(opts, :speed, 1.0)),
         {:ok, pitch_shift} <- validate_float(:pitch_shift, Keyword.get(opts, :pitch_shift, 0.0)),
         {:ok, pitch_range} <- validate_float(:pitch_range, Keyword.get(opts, :pitch_range, 1.0)) do
      {:ok,
       %{
         voice_id: voice_id,
         sample_rate: sample_rate,
         speed: speed,
         pitch_shift: pitch_shift,
         pitch_range: pitch_range
       }}
    end
  end

  defp validate_model(model) when is_binary(model) do
    if MapSet.member?(@models, model),
      do: {:ok, model},
      else: {:error, {:unknown_model, model, MapSet.to_list(@models)}}
  end

  defp validate_model(other), do: {:error, {:unknown_model, other, MapSet.to_list(@models)}}

  defp validate_voice(voice) when is_binary(voice) do
    case Map.fetch(@voices, String.upcase(voice)) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unsupported_voice, voice, Map.keys(@voices)}}
    end
  end

  defp validate_voice(other), do: {:error, {:unsupported_voice, other, Map.keys(@voices)}}

  defp validate_sample_rate(rate) when is_integer(rate) and rate > 0, do: {:ok, rate}
  defp validate_sample_rate(other), do: {:error, {:unsupported_sample_rate, other}}

  defp validate_positive_float(_key, v) when is_number(v) and v > 0, do: {:ok, v * 1.0}
  defp validate_positive_float(key, v), do: {:error, {:invalid_option, key, v}}

  defp validate_float(_key, v) when is_number(v), do: {:ok, v * 1.0}
  defp validate_float(key, v), do: {:error, {:invalid_option, key, v}}
end
