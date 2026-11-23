defmodule Octoroom.Agent.Audio.Mixer do
  @moduledoc """
  Mixes several inputs of s16le mono PCM into one stream, a chunk at a time,
  for a model that has one audio input (Gemini Live).

  Inputs arrive in real time but not in step, so the caller pulls a chunk
  on its own clock (`pull/1` every `chunk_ms`) and each input gives what it
  has. An input starts being mixed once it has two chunks buffered, which
  rides out a frame arriving just after the pull instead of mixing in a gap
  of silence. It stops when it runs dry, and buffers at most `max_ms`
  (the oldest is dropped), so a burst doesn't add latency for good.
  """

  @enforce_keys [:chunk]
  defstruct [:chunk, :max, inputs: %{}]

  @type t :: %__MODULE__{}

  @doc "Options: `:rate` (default 16 kHz), `:chunk_ms` (20), `:max_ms` (200)."
  def new(opts \\ []) do
    rate = Keyword.get(opts, :rate, 16_000)
    bytes = fn ms -> div(rate * ms, 1_000) * 2 end

    %__MODULE__{
      chunk: bytes.(Keyword.get(opts, :chunk_ms, 20)),
      max: bytes.(Keyword.get(opts, :max_ms, 200))
    }
  end

  def push(%__MODULE__{} = mixer, input, pcm) when is_binary(pcm) do
    %{buffer: buffer, primed?: primed?} =
      Map.get(mixer.inputs, input, %{buffer: <<>>, primed?: false})

    buffer = buffer <> pcm
    over = byte_size(buffer) - mixer.max
    buffer = if over > 0, do: binary_part(buffer, over, mixer.max), else: buffer
    primed? = primed? or byte_size(buffer) >= 2 * mixer.chunk
    put_in(mixer.inputs[input], %{buffer: buffer, primed?: primed?})
  end

  def drop(%__MODULE__{} = mixer, input), do: %{mixer | inputs: Map.delete(mixer.inputs, input)}

  @doc "One chunk of the inputs mixed, or nil when none is being mixed."
  def pull(%__MODULE__{} = mixer) do
    {chunks, inputs} =
      Enum.reduce(mixer.inputs, {[], mixer.inputs}, fn
        {input, %{primed?: true, buffer: buffer}}, {chunks, inputs} ->
          size = min(byte_size(buffer), mixer.chunk)
          <<chunk::binary-size(^size), rest::binary>> = buffer
          chunk = chunk <> :binary.copy(<<0>>, mixer.chunk - size)
          state = %{buffer: rest, primed?: rest != <<>>}
          {[chunk | chunks], Map.put(inputs, input, state)}

        _not_primed, acc ->
          acc
      end)

    mixer = %{mixer | inputs: inputs}

    case chunks do
      [] -> {nil, mixer}
      [one] -> {one, mixer}
      [first | rest] -> {Enum.reduce(rest, first, &add/2), mixer}
    end
  end

  defp add(a, b), do: add(a, b, []) |> IO.iodata_to_binary()

  defp add(<<x::signed-little-16, a::binary>>, <<y::signed-little-16, b::binary>>, acc),
    do: add(a, b, [acc | <<clamp(x + y)::signed-little-16>>])

  defp add(<<>>, <<>>, acc), do: acc

  defp clamp(s) when s > 32_767, do: 32_767
  defp clamp(s) when s < -32_768, do: -32_768
  defp clamp(s), do: s
end
