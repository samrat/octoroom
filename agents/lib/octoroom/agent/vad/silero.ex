defmodule Octoroom.Agent.VAD.Silero do
  @moduledoc """
  Silero VAD (v5 ONNX) speech-probability analyzer for 16 kHz mono PCM16 audio.

  Each analyzer holds its own recurrent state, so create one per audio stream.
  The ONNX model is loaded once per path and shared between streams.

  Audio is consumed in 512-sample (32 ms) frames; leftovers are buffered until
  the next call. Like the reference implementation, each frame is prefixed with
  the last 64 samples of the previous frame.
  """

  @sample_rate 16_000
  @frame_samples 512
  @context_samples 64
  @bytes_per_sample 2
  @frame_bytes @frame_samples * @bytes_per_sample
  @context_bytes @context_samples * @bytes_per_sample

  defstruct [:model, :state, context: <<0::size(@context_bytes * 8)>>, buffer: <<>>]

  @type t :: %__MODULE__{}

  def sample_rate, do: @sample_rate
  def frame_ms, do: div(@frame_samples * 1_000, @sample_rate)

  def default_model_path do
    Application.app_dir(:octoroom_agents, "priv/models/silero_vad.onnx")
  end

  @doc """
  Loads (or reuses) the ONNX model and returns a fresh analyzer.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    path = Keyword.get(opts, :model_path) || default_model_path()

    with {:ok, model} <- load_model(path) do
      {:ok, %__MODULE__{model: model, state: initial_state()}}
    end
  end

  @doc """
  Appends PCM16 audio and returns the speech probability of every complete
  frame it produced, in order.
  """
  @spec process(t(), binary()) :: {[float()], t()}
  def process(%__MODULE__{} = silero, pcm) when is_binary(pcm) do
    run_frames(%{silero | buffer: silero.buffer <> pcm}, [])
  end

  @doc "Clears recurrent state and buffered audio."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = silero) do
    %{silero | state: initial_state(), context: <<0::size(@context_bytes * 8)>>, buffer: <<>>}
  end

  defp run_frames(%{buffer: <<frame::binary-size(@frame_bytes), rest::binary>>} = silero, acc) do
    {probability, state} = infer(silero.model, silero.context <> frame, silero.state)
    context = binary_part(frame, @frame_bytes - @context_bytes, @context_bytes)

    run_frames(%{silero | state: state, context: context, buffer: rest}, [probability | acc])
  end

  defp run_frames(silero, acc), do: {Enum.reverse(acc), silero}

  defp infer(model, pcm, state) do
    input =
      pcm
      |> Nx.from_binary(:s16)
      |> Nx.as_type(:f32)
      |> Nx.divide(32_768.0)
      |> Nx.reshape({1, @frame_samples + @context_samples})

    sr = Nx.tensor(@sample_rate, type: :s64)

    {output, next_state} = Ortex.run(model, {input, state, sr})

    probability =
      output
      |> Nx.backend_transfer(Nx.BinaryBackend)
      |> Nx.reshape({})
      |> Nx.to_number()

    {probability, Nx.backend_transfer(next_state, Nx.BinaryBackend)}
  end

  defp initial_state, do: Nx.broadcast(Nx.tensor(0.0, type: :f32), {2, 1, 128})

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
            error -> {:error, {:silero_load_failed, Exception.message(error)}}
          end
        else
          {:error, {:silero_model_missing, path}}
        end

      model ->
        {:ok, model}
    end
  end
end
