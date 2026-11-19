defmodule Hello.Questions do
  @moduledoc """
  Recorded test questions, so a turn can be timed the same way every time
  without anyone talking. The page plays one into its mic track, and the
  agent hears it as it would hear you.

  They're WAVs in `priv/static/questions/`, made once with AssemblyAI:

      ASSEMBLY_AI_API_KEY=... mix run -e "Hello.Questions.record()"

  AssemblyAI allows five speech sessions a minute, so it waits between
  questions.
  """

  @questions [
    "What is the capital of France?",
    "How many legs does a spider have?",
    "Name a primary colour.",
    "What is two plus two?"
  ]

  @rate 24_000

  def all, do: @questions

  @doc "The URL of question `index`'s recording."
  def path(index), do: "/questions/#{index}.wav"

  @doc "Synthesizes every question into `priv/static/questions/`."
  def record do
    dir = Path.join(:code.priv_dir(:hello), "static/questions")
    File.mkdir_p!(dir)

    for {text, index} <- Enum.with_index(@questions) do
      if index > 0, do: Process.sleep(15_000)
      {:ok, audio} = Octoroom.Agent.TTS.synthesize("assembly_ai", text, sample_rate: @rate)

      file = Path.join(dir, "#{index}.wav")
      File.write!(file, to_wav(audio))
      IO.puts("#{file}: #{text}")
    end

    :ok
  end

  defp to_wav(<<"RIFF", _::binary>> = wav), do: wav

  defp to_wav(pcm) do
    size = byte_size(pcm)

    <<"RIFF", 36 + size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      @rate::little-32, @rate * 2::little-32, 2::little-16, 16::little-16, "data",
      size::little-32, pcm::binary>>
  end
end
