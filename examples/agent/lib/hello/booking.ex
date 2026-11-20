defmodule Hello.Booking do
  @moduledoc """
  An agent that books appointments from a script, with no LLM: a decision
  model works out what you meant, and `Hello.Booking.Script` picks what to
  say next.

  The script is data, so it could as well come from a database or an
  editor where someone who doesn't write Elixir builds their own: the
  processor runs any script of this shape. This one is `script/0`.

  `pipeline/1` builds the agent's pipeline from scratch instead of from a
  backend:

      front (one per speaker): vad -> stt -> turns -> decisions
      back:                    script -> context -> chunker -> tts -> collector

  Soniox hears you, Cloudflare's Clef Flash (through OpenRouter) judges each
  turn's transcript, and AssemblyAI speaks. Run the example with
  `HELLO_AGENT=booking` to talk to it instead of `Hello.Assistant`.
  """
  use Octoroom.Agent

  import Octoroom.Agent.Pipeline.Spec

  alias Hello.Booking.Script
  alias Octoroom.Agent.Processors

  @start "greet"

  @impl true
  def pipeline(_ctx) do
    script = script()

    front =
      processor(:vad, Processors.VAD)
      |> processor(:stt, Processors.STT, provider: :soniox)
      |> processor(:turns, Processors.STTTurns, interrupt: false)
      |> processor(:decisions, Processors.Decisions,
        model: "openrouter:cloudflare/clef-flash",
        questions: script[@start].questions,
        questions_id: @start
      )

    back =
      processor(:script, Script, script: script, start: @start)
      |> processor(:context, Processors.Context)
      |> processor(:chunker, Processors.TextChunker)
      |> processor(:tts, Processors.TTS, provider: :assembly_ai)
      |> processor(:collector, Processors.AssistantCollector)

    {front, back}
  end

  # Capitalized: the chosen day is said back as it is.
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday)

  @doc "The script: states by name, starting at `\"greet\"`."
  def script do
    %{
      "greet" => %{
        say: "Hi, this is the clinic. Would you like to book an appointment, or cancel one?",
        questions: %{
          "intent" =>
            choice("What does the caller want to do?", %{
              "book" => "Book or make an appointment.",
              "cancel" => "Cancel an appointment they have."
            })
        },
        rules: [
          %{if: {"intent", "book"}, goto: "day"},
          %{if: {"intent", "cancel"}, goto: "cancelled"},
          %{if: :else, say: "Sorry, I didn't catch that. Booking, or cancelling?"}
        ]
      },
      "day" => %{
        say: "Which day suits you? We're open Monday to Friday.",
        questions: %{
          "day" =>
            choice(
              "Which weekday does the caller want the appointment on?",
              Map.new(@weekdays, &{&1, &1 <> "."})
            )
        },
        rules: [
          %{if: {"day", :any}, save: "day", goto: "confirm"},
          %{if: :else, say: "Sorry, which day? Any day from Monday to Friday."}
        ]
      },
      "confirm" => %{
        say: "So that's {day}. Shall I book it?",
        questions: %{
          "yes" => %{type: :boolean, instructions: "Does the caller agree to the booking?"}
        },
        rules: [
          %{if: {"yes", true}, goto: "booked"},
          %{if: {"yes", false}, goto: "day"},
          %{if: :else, say: "Sorry, shall I book {day}? Yes or no?"}
        ]
      },
      "booked" => %{say: "You're booked in for {day}. See you then, goodbye!"},
      "cancelled" => %{say: "I've cancelled your appointment. Goodbye!"}
    }
  end

  # Every choice question has a way out, so the model isn't pushed into a
  # wrong answer; the rules treat it as no match.
  defp choice(instructions, criteria) do
    %{
      type: :choice,
      instructions: instructions,
      criteria: Map.put(criteria, "unclear", "None of these, or it isn't clear.")
    }
  end
end
