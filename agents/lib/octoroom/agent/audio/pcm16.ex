defmodule Octoroom.Agent.Audio.PCM16 do
  @moduledoc false

  @bytes_per_sample 2

  def fade_edges(audio, opts \\ []) when is_binary(audio) do
    sample_rate = Keyword.get(opts, :sample_rate, 24_000)
    channels = Keyword.get(opts, :channels, 1)
    duration_ms = Keyword.get(opts, :duration_ms, 5)

    frame_size = @bytes_per_sample * channels
    frame_count = div(byte_size(audio), frame_size)
    requested_fade_frames = div(sample_rate * duration_ms, 1_000)
    fade_frames = min(requested_fade_frames, div(frame_count, 2))

    cond do
      fade_frames <= 0 ->
        audio

      rem(byte_size(audio), frame_size) != 0 ->
        audio

      true ->
        audio
        |> fade_frames(channels, frame_count, fade_frames, 0, [])
        |> IO.iodata_to_binary()
    end
  end

  defp fade_frames(<<>>, _channels, _frame_count, _fade_frames, _frame_index, acc),
    do: Enum.reverse(acc)

  defp fade_frames(audio, channels, frame_count, fade_frames, frame_index, acc) do
    {frame, rest} = take_frame(audio, channels, [])
    factor = fade_factor(frame_index, frame_count, fade_frames)
    frame = Enum.map(frame, &scale_sample(&1, factor))

    fade_frames(rest, channels, frame_count, fade_frames, frame_index + 1, [frame | acc])
  end

  defp take_frame(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp take_frame(<<sample::little-signed-16, rest::binary>>, channels, acc),
    do: take_frame(rest, channels - 1, [sample | acc])

  defp fade_factor(frame_index, frame_count, fade_frames) do
    fade_in = frame_index / fade_frames
    fade_out = (frame_count - frame_index - 1) / fade_frames

    min(1.0, min(fade_in, fade_out))
  end

  defp scale_sample(sample, factor) do
    scaled = round(sample * factor)
    <<clamp_sample(scaled)::little-signed-16>>
  end

  @doc """
  Resamples mono s16le PCM from `from_rate` to `to_rate`.

  Use `resample_stream/4` when feeding chunks of one stream so boundaries stay
  continuous without clicks.
  """
  def resample(audio, from_rate, to_rate) when is_binary(audio) do
    {out, _state} = resample_stream(audio, from_rate, to_rate, nil)
    out
  end

  @doc """
  Streaming mono s16le PCM resampler. Pass `nil` as the initial state and feed
  the returned state into the next call.
  """
  def resample_stream(audio, rate, rate, state) when is_binary(audio), do: {audio, state}
  def resample_stream(<<>>, _from_rate, _to_rate, state), do: {<<>>, state}

  # Exact 2:3 upsampling (e.g. 16 kHz -> 24 kHz) with zero buffering delay:
  # phase 0 emits 1 sample at -1/3, phase 1 emits 2 samples at +1/3 and +1.
  def resample_stream(audio, 16_000, 24_000, state) when is_binary(audio) do
    %{prev: prev, phase: phase} = state || %{prev: 0, phase: 0}
    {out, prev, phase} = upsample_2_to_3(audio, prev, phase, [])
    {IO.iodata_to_binary(out), %{prev: prev, phase: phase}}
  end

  # Exact 3:2 downsampling (e.g. 24 kHz -> 16 kHz):
  # phase 0 emits s0, phase 1 holds s1, phase 2 emits midpoint of s1 and s2.
  def resample_stream(audio, 24_000, 16_000, state) when is_binary(audio) do
    %{prev: prev, phase: phase} = state || %{prev: 0, phase: 0}
    {out, prev, phase} = downsample_3_to_2(audio, prev, phase, [])
    {IO.iodata_to_binary(out), %{prev: prev, phase: phase}}
  end

  def resample_stream(audio, from_rate, to_rate, state)
      when is_binary(audio) and is_integer(from_rate) and from_rate > 0 and
             is_integer(to_rate) and to_rate > 0 do
    %{prev: prev, frac: frac} = state || %{prev: 0, frac: 0.0}
    step = from_rate / to_rate
    {out, prev, frac} = resample_linear(audio, prev, frac, step, [])
    {IO.iodata_to_binary(out), %{prev: prev, frac: frac}}
  end

  defp upsample_2_to_3(<<s0::little-signed-16, rest::binary>>, prev, 0, acc) do
    o0 = clamp_sample(round((prev + 2 * s0) / 3))
    upsample_2_to_3(rest, s0, 1, [<<o0::little-signed-16>> | acc])
  end

  defp upsample_2_to_3(<<s1::little-signed-16, rest::binary>>, prev, 1, acc) do
    o1 = clamp_sample(round((2 * prev + s1) / 3))
    upsample_2_to_3(rest, s1, 0, [<<o1::little-signed-16, s1::little-signed-16>> | acc])
  end

  defp upsample_2_to_3(_trailing, prev, phase, acc), do: {Enum.reverse(acc), prev, phase}

  defp downsample_3_to_2(<<s0::little-signed-16, rest::binary>>, _prev, 0, acc) do
    downsample_3_to_2(rest, s0, 1, [<<s0::little-signed-16>> | acc])
  end

  defp downsample_3_to_2(<<s1::little-signed-16, rest::binary>>, _prev, 1, acc) do
    downsample_3_to_2(rest, s1, 2, acc)
  end

  defp downsample_3_to_2(<<s2::little-signed-16, rest::binary>>, prev, 2, acc) do
    mid = clamp_sample(round((prev + s2) / 2))
    downsample_3_to_2(rest, s2, 0, [<<mid::little-signed-16>> | acc])
  end

  defp downsample_3_to_2(_trailing, prev, phase, acc), do: {Enum.reverse(acc), prev, phase}

  defp resample_linear(<<sample::little-signed-16, rest::binary>>, prev, frac, step, acc) do
    {acc, frac} = emit_linear(prev, sample, frac, step, acc)
    resample_linear(rest, sample, frac - 1.0, step, acc)
  end

  defp resample_linear(_trailing, prev, frac, _step, acc), do: {Enum.reverse(acc), prev, frac}

  defp emit_linear(prev, curr, frac, step, acc) when frac < 1.0 do
    val = clamp_sample(round(prev + (curr - prev) * frac))
    emit_linear(prev, curr, frac + step, step, [<<val::little-signed-16>> | acc])
  end

  defp emit_linear(_prev, _curr, frac, _step, acc), do: {acc, frac}

  defp clamp_sample(sample) when sample > 32_767, do: 32_767
  defp clamp_sample(sample) when sample < -32_768, do: -32_768
  defp clamp_sample(sample), do: sample
end
