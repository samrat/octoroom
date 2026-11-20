defmodule Hello.Booking.Script do
  @moduledoc """
  A processor that answers from a script instead of an LLM: an example of
  writing your own pipeline stage.

  The script is data (see `Hello.Booking` for one), a map of states by name:

      %{
        "greet" => %{
          say: "Hi! Would you like to book an appointment, or cancel one?",
          questions: %{"intent" => %{type: :choice, instructions: "...", criteria: %{...}}},
          rules: [
            %{if: {"intent", "book"}, goto: "day"},
            %{if: {"intent", "cancel"}, goto: "cancelled"},
            %{if: :else, say: "Sorry, was that booking or cancelling?"}
          ]
        },
        ...
      }

  Entering a state says its `say` and gives the decision model (the front
  end's `:decisions` stage) that state's `questions`, with an
  `Octoroom.Agent.Frames.UpdateStage`, so each turn is judged on only what
  the state needs to know.

  Each turn then goes through the state's `rules`, and the first that
  matches says its `say` (if any) and moves to its `goto` (if any). A rule's
  `if` is one of:

    * `{question, choice}` - a `:choice` question's answer is `choice`, with
      at least `min` confidence (default 0.6)
    * `{question, :any}` - any choice but `"unclear"`, with that confidence
    * `{question, true}` / `{question, false}` - a `:boolean` question's
      probability is at least `min`, or at most `1 - min`
    * `:else` - always

  `save: "name"` keeps the rule's answer (the choice) as `name`, and
  `{name}` in a `say` is replaced with it. A state with no rules ignores
  turns: the script is over.

  Answers to the questions of a state the script has left (a turn that was
  being judged when it moved on) match only `:else`, as does a turn the
  decision model couldn't judge.

  The processor is a `Octoroom.Agent.Processor.StateMachine` whose states
  are the script's states. It sits at the front of the back end, before
  `Octoroom.Agent.Processors.Context`: each turn goes on to the context with
  `respond: false`, so it's in the conversation without starting an LLM
  reply, and each line the script says goes downstream the way an LLM's
  reply would (`LLMResponseStart`, `LLMText`, `LLMResponseEnd`), for the
  chunker and TTS to speak.

  Options: `:script` (required), `:start` (the first state, required), and
  `:greet_delay_ms` (100), how long after the call starts to enter it.
  """
  use Octoroom.Agent.Processor.StateMachine

  @min 0.6

  @impl true
  def init(opts, _ctx) do
    data = %{
      script: Keyword.fetch!(opts, :script),
      start: Keyword.fetch!(opts, :start),
      greet_delay_ms: Keyword.get(opts, :greet_delay_ms, 100),
      vars: %{}
    }

    {:ok, :not_started, data}
  end

  @impl true
  def handle_event(%Frames.Start{} = frame, :not_started, data),
    do:
      {:keep_state_and_data, [{:push, frame, :downstream}, {:timer, :start, data.greet_delay_ms}]}

  def handle_event({:timer, :start}, :not_started, data), do: {:next_state, data.start, data}

  # Someone spoke before the greeting: their turn waits for the first state.
  def handle_event(%Frames.Transcription{respond: true}, :not_started, _data),
    do: {:keep_state_and_data, [:postpone]}

  def handle_event(%Frames.Transcription{respond: true} = turn, name, data) do
    heard = {:push, %{turn | respond: false}, :downstream}

    case Enum.find(rules(name, data), &matches?(&1, turn.decision, name)) do
      nil ->
        {:keep_state_and_data, [heard]}

      rule ->
        data = save(rule, turn.decision, data)
        actions = [heard | say(rule[:say], data)]

        case rule[:goto] do
          nil -> {:keep_state, data, actions}
          next -> {:next_state, next, data, actions}
        end
    end
  end

  @impl true
  def state_enter(_old, name, data) do
    state = Map.fetch!(data.script, name)
    questions = Map.get(state, :questions, %{})

    update = %Frames.UpdateStage{
      stage: :decisions,
      opts: [questions: questions, questions_id: name]
    }

    {:keep_state, data, [{:push, update, :upstream} | say(state[:say], data)]}
  end

  # -- rules

  defp rules(name, data), do: data.script |> Map.fetch!(name) |> Map.get(:rules, [])

  defp matches?(%{if: :else}, _decision, _name), do: true

  defp matches?(%{if: {question, expected}} = rule, %{questions_id: name} = decision, name) do
    min = Map.get(rule, :min, @min)

    case {expected, decision.answers[question]} do
      {bool, %{"probability" => p}} when is_boolean(bool) and is_number(p) ->
        if bool, do: p >= min, else: p <= 1 - min

      {:any, %{"choice" => choice, "confidence" => c}} when is_number(c) ->
        choice != "unclear" and c >= min

      {choice, %{"choice" => choice, "confidence" => c}} when is_number(c) ->
        c >= min

      _other ->
        false
    end
  end

  # No decision, or one for another state's questions.
  defp matches?(_rule, _decision, _name), do: false

  defp save(%{save: var, if: {question, _}}, decision, data),
    do: put_in(data.vars[var], get_in(decision.answers, [question, "choice"]))

  defp save(_rule, _decision, data), do: data

  # -- saying

  defp say(nil, _data), do: []

  defp say(text, data) do
    text = Regex.replace(~r/\{(\w+)\}/, text, fn whole, var -> data.vars[var] || whole end)

    for frame <- [
          %Frames.LLMResponseStart{},
          %Frames.LLMText{text: text},
          %Frames.LLMResponseEnd{}
        ],
        do: {:push, frame, :downstream}
  end
end
