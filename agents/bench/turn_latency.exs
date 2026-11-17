# Server-side turn latency against real providers, with no room or browser.
#
#     cd agents
#     SONIOX_API_KEY=... GOOGLE_API_KEY=... INWORLD_API_KEY=... mix run bench/turn_latency.exs
#
# Synthesizes a spoken question with Inworld, then feeds it to
# `Octoroom.Agent.Worker` in 20 ms frames at real time, as a room would,
# followed by silence. Prints what the agent emits, including its
# `{:latency, ...}` report, and when its first audio would reach the outlet.
# `Q="..."` asks something else.

alias Octoroom.Agent.Cascaded.Inworld
alias Octoroom.Agent.Worker

question = System.get_env("Q", "What is the capital of France? Answer in one word.")

{:ok, speech24} =
  Inworld.speech(
    token: System.fetch_env!("INWORLD_API_KEY"),
    input: question,
    model: "inworld-tts-2",
    voice: "Ashley",
    audio_encoding: "LINEAR16",
    sample_rate: 24_000
  )

speech24 =
  case speech24 do
    <<"RIFF", _::binary-size(40), pcm::binary>> -> pcm
    pcm -> pcm
  end

# 24 kHz to 16 kHz: average each pair of the 3 samples into 2 (crude; fine for STT).
speech16 =
  for <<a::little-signed-16, b::little-signed-16, c::little-signed-16 <- speech24>>,
    into: <<>>,
    do: <<div(2 * a + b, 3)::little-signed-16, div(b + 2 * c, 3)::little-signed-16>>

lead_ms = 1_000
audio = :binary.copy(<<0, 0>>, 16 * lead_ms) <> speech16 <> :binary.copy(<<0, 0>>, 16 * 5_000)
chunks = for <<c::binary-size(640) <- audio>>, do: c

defmodule Bench do
  def handle({:ok, state}, _t0), do: state

  def handle({:ok, state, actions}, t0) do
    for action <- actions do
      case action do
        {:play, {_, pcm}} ->
          if Process.get(:first_play) == nil, do: Process.put(:first_play, ms(t0))
          Process.put(:played, (Process.get(:played) || 0) + byte_size(pcm))

        {:emit, {:agent, {:transcription, %{status: "partial"}}}} ->
          :ok

        {:emit, event} ->
          IO.puts("#{ms(t0)} ms  #{inspect(event)}")

        other ->
          IO.puts("#{ms(t0)} ms  #{inspect(other)}")
      end
    end

    state
  end

  def ms(t0), do: System.monotonic_time(:millisecond) - t0

  # Hands messages to the worker until `until`.
  def drain(state, t0, until) do
    receive do
      message -> message |> Worker.handle_info(state) |> handle(t0) |> drain(t0, until)
    after
      max(until - System.monotonic_time(:millisecond), 0) -> state
    end
  end
end

# A room's worker traps exits; so does this stand-in for one.
Process.flag(:trap_exit, true)

ctx = %Octoroom.Worker.Context{
  room_id: "bench",
  id: "assistant",
  inputs: ["me/mic"],
  outputs: ["assistant"]
}

t0 = System.monotonic_time(:millisecond)
{:ok, state} = Worker.init(%{instructions: "You are a voice assistant. Be very brief."}, ctx)

IO.puts(
  "question: #{inspect(question)}, speech ends at ~#{lead_ms + div(byte_size(speech16), 32)} ms"
)

state =
  chunks
  |> Enum.with_index(1)
  |> Enum.reduce(state, fn {chunk, i}, state ->
    "me/mic"
    |> Worker.handle_audio(chunk, state)
    |> Bench.handle(t0)
    |> Bench.drain(t0, t0 + i * 20)
  end)

state = Bench.drain(state, t0, System.monotonic_time(:millisecond) + 2_000)
played = (Process.get(:played) || 0) / 48_000

IO.puts(
  "first audio to the outlet at #{inspect(Process.get(:first_play))} ms; #{played} s of reply"
)

Worker.terminate(:normal, state)
