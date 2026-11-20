defmodule Hello.BookingTest do
  # The script on its own, fed turns with made-up answers from the decision
  # model: no audio, no providers.
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness

  # Started, and past the greeting delay.
  defp start do
    harness =
      processor(:script, Hello.Booking.Script, script: Hello.Booking.script(), start: "greet")
      |> Harness.start!()
      |> Harness.push(%Frames.Start{})

    Harness.fire_timer(harness, :script, :start)
  end

  defp turn(harness, text, questions_id, answers) do
    decision = %{questions_id: questions_id, answers: answers}
    Harness.push(harness, %Frames.Transcription{text: text, turn_id: 1, decision: decision})
  end

  defp choice(question, choice, confidence \\ 0.9),
    do: %{question => %{"choice" => choice, "confidence" => confidence}}

  defp said(harness), do: harness |> Harness.outputs(Frames.LLMText) |> Enum.map(& &1.text)

  defp questions_ids(harness),
    do: for(%Frames.UpdateStage{opts: opts} <- Harness.upstream(harness), do: opts[:questions_id])

  test "books a day, start to finish" do
    harness = start()
    assert said(harness) == [Hello.Booking.script()["greet"].say]
    assert questions_ids(harness) == ["greet"]

    harness =
      harness
      |> turn("I'd like to book", "greet", choice("intent", "book"))
      |> turn("Tuesday please", "day", choice("day", "Tuesday"))
      |> turn("Yes", "confirm", %{"yes" => %{"probability" => 0.93}})

    assert Enum.drop(said(harness), 1) == [
             "Which day suits you? We're open Monday to Friday.",
             "So that's Tuesday. Shall I book it?",
             "You're booked in for Tuesday. See you then, goodbye!"
           ]

    assert questions_ids(harness) == ["greet", "day", "confirm", "booked"]

    # Every turn went on as history, without starting an LLM reply.
    assert [_, _, _] = turns = Harness.outputs(harness, Frames.Transcription)
    assert Enum.all?(turns, &(&1.respond == false))
  end

  test "an unsure answer asks again, in the same state" do
    harness = start() |> turn("Hmm", "greet", choice("intent", "book", 0.4))

    assert List.last(said(harness)) == "Sorry, I didn't catch that. Booking, or cancelling?"
    assert questions_ids(harness) == ["greet"]
  end

  test "\"unclear\" is no day" do
    harness =
      start()
      |> turn("Book please", "greet", choice("intent", "book"))
      |> turn("Whenever", "day", choice("day", "unclear"))

    assert List.last(said(harness)) == "Sorry, which day? Any day from Monday to Friday."
  end

  test "answers to an earlier state's questions only match :else" do
    harness =
      start()
      |> turn("Book please", "greet", choice("intent", "book"))
      # Judged with the greeting's questions while the script moved on.
      |> turn("Book please", "greet", choice("intent", "book"))

    assert List.last(said(harness)) == "Sorry, which day? Any day from Monday to Friday."
  end

  test "a turn before the greeting waits for it" do
    harness =
      processor(:script, Hello.Booking.Script, script: Hello.Booking.script(), start: "greet")
      |> Harness.start!()
      |> Harness.push(%Frames.Start{})
      |> turn("Cancel my appointment", "greet", choice("intent", "cancel"))

    assert said(harness) == []

    harness = Harness.fire_timer(harness, :script, :start)

    assert said(harness) == [
             Hello.Booking.script()["greet"].say,
             "I've cancelled your appointment. Goodbye!"
           ]
  end

  test "its pipeline is valid" do
    {front, back} = Hello.Booking.pipeline(%{})
    assert {:ok, _} = validate(front)
    assert {:ok, _} = validate(back)
  end
end
