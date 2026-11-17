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

  defp clamp_sample(sample) when sample > 32_767, do: 32_767
  defp clamp_sample(sample) when sample < -32_768, do: -32_768
  defp clamp_sample(sample), do: sample
end
