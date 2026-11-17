defmodule Octoroom.Agent.TurnDetection.SmartTurn do
  @moduledoc """
  Pipecat's Smart Turn v3 end-of-turn classifier for 16 kHz mono PCM16 audio.

  Smart Turn listens to the raw waveform of the user's current turn (prosody,
  intonation, fillers) and returns the probability that they have finished
  speaking. It is meant to run when the VAD first reports silence: a low score
  means the user is only pausing, so the agent should keep listening.

  The analyzer keeps the last 8 seconds of the turn's audio. Two ONNX models do
  the work and are loaded once per path, then shared between streams:

    * `smart_turn_features.onnx` turns the 8 s window into the Whisper log-mel
      spectrogram the classifier expects (built by
      `priv/models/build_smart_turn_features.py`)
    * `smart-turn-v3.2-cpu.onnx` is the int8 classifier from
      <https://huggingface.co/pipecat-ai/smart-turn-v3>
  """

  @sample_rate 16_000
  @window_samples 8 * @sample_rate
  @bytes_per_sample 2
  @window_bytes @window_samples * @bytes_per_sample

  defstruct [:model, :features, buffer: <<>>]

  @type t :: %__MODULE__{}

  def sample_rate, do: @sample_rate
  def window_ms, do: div(@window_samples * 1_000, @sample_rate)

  def default_model_path,
    do: Application.app_dir(:octoroom_agents, "priv/models/smart-turn-v3.2-cpu.onnx")

  def default_features_model_path,
    do: Application.app_dir(:octoroom_agents, "priv/models/smart_turn_features.onnx")

  @doc """
  Loads (or reuses) the ONNX models and returns an analyzer with no audio.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    model_path = Keyword.get(opts, :model_path) || default_model_path()
    features_path = Keyword.get(opts, :features_model_path) || default_features_model_path()

    with {:ok, model} <- load_model(model_path),
         {:ok, features} <- load_model(features_path) do
      {:ok, %__MODULE__{model: model, features: features}}
    end
  end

  @doc "Appends PCM16 audio, keeping only the most recent 8 seconds."
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = smart_turn, pcm) when is_binary(pcm) do
    %{smart_turn | buffer: keep_last(smart_turn.buffer <> pcm, @window_bytes)}
  end

  @doc "Drops all but the most recent `ms` of audio."
  @spec keep_last_ms(t(), non_neg_integer()) :: t()
  def keep_last_ms(%__MODULE__{} = smart_turn, ms) do
    bytes = div(ms * @sample_rate, 1_000) * @bytes_per_sample
    %{smart_turn | buffer: keep_last(smart_turn.buffer, bytes)}
  end

  @doc "Clears buffered audio."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = smart_turn), do: %{smart_turn | buffer: <<>>}

  @doc "Buffered audio duration in milliseconds."
  @spec buffered_ms(t()) :: non_neg_integer()
  def buffered_ms(%__MODULE__{buffer: buffer}),
    do: div(byte_size(buffer) * 1_000, @sample_rate * @bytes_per_sample)

  @doc """
  Returns the probability (0.0 to 1.0) that the buffered turn is complete.
  """
  @spec predict(t()) :: float()
  def predict(%__MODULE__{} = smart_turn), do: predict_pcm(smart_turn, smart_turn.buffer)

  @doc false
  def predict_pcm(%__MODULE__{model: model, features: features}, pcm) do
    pcm = keep_last(pcm, @window_bytes)
    # Like the reference implementation, shorter turns are zero-padded at the start.
    padding = <<0::size((@window_bytes - byte_size(pcm)) * 8)>>

    # The features model scales int16 to float itself; doing it here in pure
    # Elixir would cost more than both models combined.
    audio = (padding <> pcm) |> Nx.from_binary(:s16) |> Nx.reshape({1, @window_samples})

    {input_features} = Ortex.run(features, {audio})
    {probability} = Ortex.run(model, {input_features})

    probability
    |> Nx.backend_transfer(Nx.BinaryBackend)
    |> Nx.reshape({})
    |> Nx.to_number()
  end

  defp keep_last(binary, bytes) when byte_size(binary) > bytes,
    do: :binary.copy(binary_part(binary, byte_size(binary) - bytes, bytes))

  defp keep_last(binary, _bytes), do: binary

  defp load_model(path) do
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      nil ->
        if File.regular?(path) do
          try do
            model = Ortex.load(path)
            :persistent_term.put(key, model)
            {:ok, model}
          rescue
            error -> {:error, {:smart_turn_load_failed, path, Exception.message(error)}}
          end
        else
          {:error, {:smart_turn_model_missing, path}}
        end

      model ->
        {:ok, model}
    end
  end
end
